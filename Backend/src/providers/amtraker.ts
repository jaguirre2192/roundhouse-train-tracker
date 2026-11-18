import type { BoardEntrySnapshot, BoardReference, StationSnapshot } from "../domain/discovery.js";
import type { CanonicalTripReference, StopSnapshot, TripSnapshot, VehiclePositionSnapshot } from "../domain/snapshot.js";
import type { NorthAmericanIntercityRouteGeometrySource } from "./north-american-intercity-gtfs-geometry.js";
import { RailProviderNotFoundError, type RailProvider } from "./provider.js";
import { amtrakerTripForReference } from "./amtraker-trip-identity.js";
import { amtrakerStopEvidence } from "./amtraker-stop-observation.js";
export { matchingAmtrakerTrain } from "./amtraker-stop-identity.js";

interface AmtrakerStation {
  name: string;
  code: string;
  lat?: number | null;
  lon?: number | null;
  city?: string | null;
  state?: string | null;
}

export interface AmtrakerStop {
  name: string;
  code: string;
  schArr?: string | null;
  schDep?: string | null;
  arr?: string | null;
  dep?: string | null;
  status?: string | null;
  platform?: string | null;
}

export interface AmtrakerAlert { message: string }

export interface AmtrakerTrain {
  trainID: string;
  trainNum: string;
  routeName: string;
  provider?: string | null;
  lat?: number | null;
  lon?: number | null;
  heading?: string | null;
  updatedAt?: string | null;
  lastValTS?: string | null;
  destName?: string | null;
  stations: AmtrakerStop[];
  alerts?: AmtrakerAlert[] | null;
}

export type AmtrakerResponse = Record<string, AmtrakerTrain[]>;
type AmtrakerStationResponse = Record<string, AmtrakerStation>;

function normalized(value: string | null | undefined): string | null {
  const result = value?.trim();
  return result === undefined || result.length === 0 ? null : result;
}

function asStop(value: AmtrakerStop, index: number, station: AmtrakerStation | undefined, train: AmtrakerTrain, now: Date): StopSnapshot {
  const status = value.status?.toLowerCase() ?? "";
  return {
    stationId: `us:amtraker:${value.code}`,
    stationName: value.name,
    countryCode: "US",
    latitude: station?.lat ?? null,
    longitude: station?.lon ?? null,
    sequence: index + 1,
    scheduledArrival: normalized(value.schArr),
    scheduledDeparture: normalized(value.schDep),
    expectedArrival: normalized(value.arr),
    expectedDeparture: normalized(value.dep),
    plannedPlatform: normalized(value.platform),
    expectedPlatform: normalized(value.platform),
    platformSource: normalized(value.platform) === null ? null : "Amtraker",
    platformObservedAt: null,
    cancelled: status.includes("cancel"),
    passed: status === "departed",
    ...amtrakerStopEvidence(value, train, now),
  };
}

const headings: Record<string, number> = { N: 0, NE: 45, E: 90, SE: 135, S: 180, SW: 225, W: 270, NW: 315 };

/** Amtraker GPS for one train instance. Hours-old or out-of-range coordinates are not a position. */
export function amtrakerPosition(train: AmtrakerTrain, now: Date): VehiclePositionSnapshot[] {
  const latitude = Number(train.lat);
  const longitude = Number(train.lon);
  const asOfText = train.lastValTS ?? train.updatedAt ?? null;
  const asOf = asOfText === null ? Number.NaN : Date.parse(asOfText);
  if (
    train.lat === null || train.lat === undefined || train.lon === null || train.lon === undefined
    || !Number.isFinite(latitude) || latitude < -90 || latitude > 90
    || !Number.isFinite(longitude) || longitude < -180 || longitude > 180
    || (latitude === 0 && longitude === 0)
    // Undated or malformed GPS has unknown age; a timestamp beyond clock skew is implausible.
    || Number.isNaN(asOf) || asOf - now.getTime() > 2 * 60_000
  ) return [];
  const age = Math.max(now.getTime() - asOf, 0);
  if (age > 60 * 60_000) return [];
  const heading = train.heading === null || train.heading === undefined ? null : headings[train.heading.toUpperCase()] ?? null;
  return [{
    latitude,
    longitude,
    heading,
    source: "real",
    confidence: age < 5 * 60_000 ? 1 : age < 15 * 60_000 ? 0.8 : 0.5,
    asOf: new Date(asOf).toISOString(),
    provider: "Amtraker",
  }];
}

function alertId(message: string): string {
  let hash = 2166136261;
  for (const character of message) {
    hash ^= character.charCodeAt(0);
    hash = Math.imul(hash, 16777619);
  }
  return `amtraker-alert-${(hash >>> 0).toString(16)}`;
}

export class AmtrakerProvider implements RailProvider {
  readonly source = "amtraker" as const;
  readonly discoveryScope = "us" as const;
  private cachedStations: { loadedAt: number; value: AmtrakerStationResponse } | null = null;
  private cachedTrains: { loadedAt: number; value: AmtrakerTrain[] } | null = null;

  constructor(
    private readonly baseUrl = "https://api.amtraker.com/v3",
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
    private readonly routeGeometrySource: NorthAmericanIntercityRouteGeometrySource | null = null,
  ) {}

  async searchStations(query: string): Promise<StationSnapshot[]> {
    const normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.length === 0) return [];
    const stations = Object.values(await this.stationCatalog());
    return stations
      .filter((station) => [station.code, station.name, station.city, station.state]
        .some((value) => value?.toLowerCase().includes(normalizedQuery) === true))
      .sort((left, right) => this.stationScore(left, normalizedQuery) - this.stationScore(right, normalizedQuery))
      .slice(0, 20)
      .map((station) => this.station(station));
  }

  async fetchBoard(reference: BoardReference): Promise<BoardEntrySnapshot[]> {
    const [stations, trains] = await Promise.all([this.stationCatalog(), this.allTrains()]);
    const requestedAt = Date.parse(reference.at);
    const lowerBound = requestedAt - 12 * 60 * 60_000;
    const upperBound = requestedAt + 24 * 60 * 60_000;
    return trains.flatMap((train): BoardEntrySnapshot[] => {
      const sequence = train.stations.findIndex((stop) => stop.code === reference.nativeId);
      if (sequence < 0) return [];
      const stop = asStop(train.stations[sequence]!, sequence, stations[reference.nativeId], train, this.now());
      const relevant = reference.direction === "arrivals"
        ? stop.expectedArrival ?? stop.scheduledArrival
        : stop.expectedDeparture ?? stop.scheduledDeparture;
      if (relevant === null) return [];
      const time = Date.parse(relevant);
      if (Number.isNaN(time) || time < lowerBound || time > upperBound) return [];
      return [{
        trip: {
          id: `us:amtraker:${train.trainID}`,
          source: this.source,
          nativeId: train.trainID,
          serviceDate: relevant.slice(0, 10),
        },
        stop,
        headsign: train.destName ?? train.stations.at(-1)?.name ?? "",
        product: [train.routeName, train.trainNum].filter(Boolean).join(" "),
      }];
    }).sort((left, right) => {
      const leftTime = reference.direction === "arrivals"
        ? left.stop.expectedArrival ?? left.stop.scheduledArrival
        : left.stop.expectedDeparture ?? left.stop.scheduledDeparture;
      const rightTime = reference.direction === "arrivals"
        ? right.stop.expectedArrival ?? right.stop.scheduledArrival
        : right.stop.expectedDeparture ?? right.stop.scheduledDeparture;
      return Date.parse(leftTime ?? "") - Date.parse(rightTime ?? "");
    });
  }

  async fetchTrip(reference: CanonicalTripReference): Promise<TripSnapshot> {
    const response = await this.fetcher(`${this.baseUrl}/trains/${encodeURIComponent(reference.nativeId)}`, {
      headers: { accept: "application/json", "user-agent": "TrainTrackerWatcher/0.1" },
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) throw new Error(`Amtraker returned ${response.status}`);

    const payload = (await response.json()) as AmtrakerResponse;
    const candidates = Object.values(payload).flat();
    const train = amtrakerTripForReference(candidates, reference);
    if (train === null) throw new RailProviderNotFoundError();

    const stations = await this.stationCatalog().catch((): AmtrakerStationResponse => ({}));
    const routeGeometry = this.routeGeometrySource === null
      ? null
      : await this.routeGeometrySource.geometryFor(
          train.provider ?? "",
          train.trainNum,
          train.stations.map((stop) => ({
            code: stop.code,
            latitude: stations[stop.code]?.lat ?? null,
            longitude: stations[stop.code]?.lon ?? null,
          })),
        ).catch(() => null);
    return {
      ...reference,
      id: `us:amtraker:${train.trainID}`,
      nativeId: train.trainID,
      operatorName: train.provider ?? "Amtrak",
      product: [train.routeName, train.trainNum].filter(Boolean).join(" "),
      headsign: train.destName ?? train.stations.at(-1)?.name ?? "",
      fetchedAt: this.now().toISOString(),
      stops: train.stations.map((value, index) => asStop(value, index, stations[value.code], train, this.now())),
      ...(routeGeometry === null ? {} : { routeGeometry }),
      ...(amtrakerPosition(train, this.now()).length === 0 ? {} : { positions: amtrakerPosition(train, this.now()) }),
      alertIds: (train.alerts ?? []).map((alert) => alertId(alert.message)),
    };
  }

  private async stationCatalog(): Promise<AmtrakerStationResponse> {
    const now = this.now().getTime();
    if (this.cachedStations !== null && now - this.cachedStations.loadedAt < 6 * 60 * 60_000) {
      return this.cachedStations.value;
    }
    const response = await this.fetcher(`${this.baseUrl}/stations`, {
      headers: { accept: "application/json", "user-agent": "TrainTrackerWatcher/0.2" },
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) throw new Error(`Amtraker stations returned ${response.status}`);
    const value = await response.json() as AmtrakerStationResponse;
    this.cachedStations = { loadedAt: now, value };
    return value;
  }

  private async allTrains(): Promise<AmtrakerTrain[]> {
    const now = this.now().getTime();
    if (this.cachedTrains !== null && now - this.cachedTrains.loadedAt < 20_000) return this.cachedTrains.value;
    const response = await this.fetcher(`${this.baseUrl}/trains`, {
      headers: { accept: "application/json", "user-agent": "TrainTrackerWatcher/0.2" },
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) throw new Error(`Amtraker trains returned ${response.status}`);
    const payload = await response.json() as AmtrakerResponse;
    const value = Object.values(payload).flat();
    this.cachedTrains = { loadedAt: now, value };
    return value;
  }

  private station(value: AmtrakerStation): StationSnapshot {
    return {
      id: `us:amtraker:${value.code}`,
      source: this.source,
      nativeId: value.code,
      name: value.name,
      countryCode: "US",
      latitude: value.lat ?? 0,
      longitude: value.lon ?? 0,
      operatorHints: ["Amtrak"],
    };
  }

  private stationScore(station: AmtrakerStation, query: string): number {
    if (station.code.toLowerCase() === query) return 0;
    if (station.name.toLowerCase().startsWith(query)) return 1;
    if (station.city?.toLowerCase().startsWith(query) === true) return 2;
    return 3;
  }
}
