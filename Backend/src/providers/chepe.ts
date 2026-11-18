import type { BoardEntrySnapshot, BoardReference, StationSnapshot } from "../domain/discovery.js";
import type { CanonicalTripReference, StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import { RailProviderNotFoundError, type RailProvider } from "./provider.js";
import { RailProviderUnavailableError } from "./rail-provider-error.js";
import { readChepeTimetable, type ChepeRoute, type ChepeRouteStop, type ChepeTimetable } from "./chepe-timetable.js";
import { ChepePublicationVerifier } from "./chepe-publication.js";

interface ChepeStation {
  nativeId: string;
  name: string;
  aliases: string[];
  latitude: number;
  longitude: number;
  utcOffset: "-07:00" | "-06:00";
}

const stations = [
  {
    nativeId: "los-mochis",
    name: "Los Mochis",
    aliases: ["Chepe Los Mochis", "Estación Los Mochis"],
    latitude: 25.7611676,
    longitude: -108.9672524,
    utcOffset: "-07:00",
  },
  {
    nativeId: "el-fuerte",
    name: "El Fuerte",
    aliases: ["Chepe El Fuerte", "Estación El Fuerte"],
    latitude: 26.3648418,
    longitude: -108.5921239,
    utcOffset: "-07:00",
  },
  {
    nativeId: "bahuichivo",
    name: "Bahuichivo",
    aliases: ["Cerocahui", "Bahuichivo/Cerocahui", "Chepe Bahuichivo"],
    latitude: 27.4119417,
    longitude: -108.0680084,
    utcOffset: "-06:00",
  },
  {
    nativeId: "divisadero",
    name: "Divisadero",
    aliases: ["Barrancas del Cobre", "Copper Canyon", "Chepe Divisadero"],
    latitude: 27.5347917,
    longitude: -107.8237464,
    utcOffset: "-06:00",
  },
  {
    nativeId: "creel",
    name: "Creel",
    aliases: ["Chepe Creel", "Estación Creel"],
    latitude: 27.7545521,
    longitude: -107.6347201,
    utcOffset: "-06:00",
  },
] as const satisfies readonly ChepeStation[];

const stationById = new Map<string, ChepeStation>(stations.map((station) => [station.nativeId, station]));

function tripNativeId(route: ChepeRoute, serviceDate: string): string {
  return `${route.nativeId}:${serviceDate}`;
}

function referencedRoute(reference: CanonicalTripReference, schedule: ChepeTimetable): ChepeRoute | null {
  const suffix = `:${reference.serviceDate}`;
  if (!reference.nativeId.endsWith(suffix)) return null;
  const name = reference.nativeId.slice(0, -suffix.length);
  return schedule.routes.find(route => route.nativeId === name) ?? null;
}

function searchable(value: string): string {
  return value.normalize("NFD").replace(/\p{Diacritic}/gu, "").toLocaleLowerCase("es-MX").trim();
}

function stationSnapshot(station: ChepeStation): StationSnapshot {
  return {
    id: `mx:chepe:${station.nativeId}`,
    source: "chepe",
    nativeId: station.nativeId,
    name: station.name,
    countryCode: "MX",
    latitude: station.latitude,
    longitude: station.longitude,
    operatorHints: ["Chepe Express", "Ferromex"],
  };
}

function dateParts(serviceDate: string): { month: number; dayOfWeek: number } | null {
  if (!/^\d{4}-\d{2}-\d{2}$/u.test(serviceDate)) return null;
  const date = new Date(`${serviceDate}T12:00:00.000Z`);
  if (!Number.isFinite(date.getTime()) || date.toISOString().slice(0, 10) !== serviceDate) return null;
  return { month: date.getUTCMonth() + 1, dayOfWeek: date.getUTCDay() };
}

function runsOn(schedule: ChepeTimetable, route: ChepeRoute, serviceDate: string): boolean {
  if (serviceDate < schedule.validFrom || serviceDate > schedule.validThrough) return false;
  const parts = dateParts(serviceDate);
  if (parts === null || !route.operatingDays.includes(parts.dayOfWeek)) return false;
  return !route.suspensions.some(period => period.months.includes(parts.month) && period.weekdays.includes(parts.dayOfWeek));
}

function instant(serviceDate: string, stop: ChepeRouteStop): string {
  const station = stationById.get(stop.stationId)!;
  return new Date(`${serviceDate}T${stop.time}${station.utcOffset}`).toISOString();
}

function tripStop(route: ChepeRoute, serviceDate: string, value: ChepeRouteStop, index: number): StopSnapshot {
  const station = stationById.get(value.stationId)!;
  const scheduled = instant(serviceDate, value);
  return {
    stationId: `mx:chepe:${station.nativeId}`,
    stationName: station.name,
    countryCode: "MX",
    latitude: station.latitude,
    longitude: station.longitude,
    sequence: index + 1,
    scheduledArrival: index === 0 ? null : scheduled,
    scheduledDeparture: index === route.stops.length - 1 ? null : scheduled,
    expectedArrival: null,
    expectedDeparture: null,
    plannedPlatform: null,
    expectedPlatform: null,
    platformSource: null,
    platformObservedAt: null,
    cancelled: false,
    passed: false,
  };
}

function shiftedDates(at: string): string[] {
  const center = new Date(at);
  if (!Number.isFinite(center.getTime())) return [];
  return [-1, 0, 1, 2].map((offset) => {
    const date = new Date(center);
    date.setUTCDate(date.getUTCDate() + offset);
    return date.toISOString().slice(0, 10);
  });
}

export class ChepeProvider implements RailProvider {
  readonly source = "chepe" as const;
  readonly discoveryScope = "international" as const;
  private readonly publication: ChepePublicationVerifier;
  private readonly timetable: ChepeTimetable | null;

  constructor(
    fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
    timetableJSON?: string,
  ) {
    this.timetable = readChepeTimetable(timetableJSON);
    this.publication = new ChepePublicationVerifier(fetcher, now, this.timetable?.publicationSignatures ?? []);
  }

  private async verifiedSchedule(): Promise<ChepeTimetable> {
    if (!this.timetable) throw new RailProviderUnavailableError("Chepe timetable is unavailable for this deployment");
    await this.publication.ensureCurrent();
    return this.timetable;
  }

  async searchStations(query: string): Promise<StationSnapshot[]> {
    const needle = searchable(query);
    if (needle.length === 0) return [];
    return stations
      .map((station) => ({
        station,
        values: [station.name, ...station.aliases, "Chepe Express", "Ferromex"].map(searchable),
      }))
      .filter(({ values }) => values.some((value) => value.includes(needle)))
      .sort((left, right) => {
        const score = (values: string[]) => values.some((value) => value === needle) ? 0
          : values.some((value) => value.startsWith(needle)) ? 1 : 2;
        return score(left.values) - score(right.values) || left.station.name.localeCompare(right.station.name);
      })
      .map(({ station }) => stationSnapshot(station));
  }

  async fetchBoard(reference: BoardReference): Promise<BoardEntrySnapshot[]> {
    const schedule = await this.verifiedSchedule();
    if (!stationById.has(reference.nativeId)) return [];
    const requestedAt = Date.parse(reference.at);
    if (!Number.isFinite(requestedAt)) return [];
    const lowerBound = requestedAt - 12 * 60 * 60_000;
    const upperBound = requestedAt + 36 * 60 * 60_000;
    const entries: BoardEntrySnapshot[] = [];

    for (const serviceDate of shiftedDates(reference.at)) {
      for (const route of schedule.routes) {
        if (!runsOn(schedule, route, serviceDate)) continue;
        const index = route.stops.findIndex((stop) => stop.stationId === reference.nativeId);
        if (index < 0) continue;
        const stop = tripStop(route, serviceDate, route.stops[index]!, index);
        const relevant = reference.direction === "arrivals" ? stop.scheduledArrival : stop.scheduledDeparture;
        if (relevant === null) continue;
        const time = Date.parse(relevant);
        if (time < lowerBound || time > upperBound) continue;
        entries.push({
          trip: {
            id: `mx:chepe:${tripNativeId(route, serviceDate)}`,
            source: this.source,
            nativeId: tripNativeId(route, serviceDate),
            serviceDate,
          },
          stop,
          headsign: route.headsign,
          product: "Chepe Express",
        });
      }
    }

    return entries.sort((left, right) => {
      const leftTime = reference.direction === "arrivals" ? left.stop.scheduledArrival : left.stop.scheduledDeparture;
      const rightTime = reference.direction === "arrivals" ? right.stop.scheduledArrival : right.stop.scheduledDeparture;
      return Date.parse(leftTime ?? "") - Date.parse(rightTime ?? "");
    });
  }

  async fetchTrip(reference: CanonicalTripReference): Promise<TripSnapshot> {
    const schedule = await this.verifiedSchedule();
    const route = referencedRoute(reference, schedule);
    if (route === null || !runsOn(schedule, route, reference.serviceDate)) throw new RailProviderNotFoundError();
    return {
      ...reference,
      operatorName: "Ferromex / Chepe Express",
      product: "Chepe Express",
      headsign: route.headsign,
      fetchedAt: this.now().toISOString(),
      stops: route.stops.map((stop, index) => tripStop(route, reference.serviceDate, stop, index)),
      alertIds: [],
    };
  }

}
