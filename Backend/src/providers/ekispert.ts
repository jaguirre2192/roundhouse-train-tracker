import type { BoardEntrySnapshot, BoardReference, StationSnapshot } from "../domain/discovery.js";
import type { CanonicalTripReference, StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import { ekispertSearchQueries } from "./ekispert-search-aliases.js";
import type {
  EkispertPoint,
  EkispertStationResponse,
  EkispertTimetable,
  EkispertTimetableResponse,
  EkispertTimetableStop,
  EkispertTripLine,
  EkispertTripResponse,
  EkispertTripStop,
  EkispertValue,
} from "./ekispert-types.js";
import {
  clockTime,
  compactDate,
  dictionary,
  isJapanMainlineName,
  japanDate,
  scheduledTime,
  valueText,
  values,
} from "./ekispert-values.js";
import { RailProviderNotFoundError, type RailProvider } from "./provider.js";

const sourceName = "Ekispert timetable";
const maximumDirectionTables = 8;

interface NativeReference {
  lineCode: string;
  stationCode: string | null;
  platform: string | null;
}

function pointStation(value: EkispertPoint): StationSnapshot {
  return {
    id: `jp:ekispert:${value.Station.code}`,
    source: "ekispert",
    nativeId: value.Station.code,
    name: value.Station.Name,
    countryCode: "JP",
    latitude: Number(value.GeoPoint?.lati_d ?? 0),
    longitude: Number(value.GeoPoint?.longi_d ?? 0),
    operatorHints: ["JR", "Shinkansen", "Japan mainline rail"],
  };
}

function stationType(value: EkispertPoint): string {
  const type = value.Station.Type;
  return (typeof type === "string" ? type : type?.text ?? type?.detail ?? "").toLowerCase();
}

function encodeNativeReference(value: NativeReference): string {
  return [value.lineCode, value.stationCode ?? "", value.platform ?? ""].join("~");
}

function decodeNativeReference(value: string): NativeReference {
  const [lineCode, stationCode, platform] = value.split("~");
  if (lineCode === undefined || lineCode.length === 0) throw new Error("Ekispert trip reference is invalid");
  return {
    lineCode,
    stationCode: stationCode?.trim() || null,
    platform: platform?.trim() || null,
  };
}

function lookup(map: Map<string, string>, key: string | undefined): string | null {
  return key === undefined ? null : map.get(key) ?? null;
}

function productName(
  timetable: EkispertTimetable,
  stop: EkispertTimetableStop,
  names: Map<string, string>,
  kinds: Map<string, string>,
): string {
  const name = lookup(names, stop.nameCode);
  const kind = lookup(kinds, stop.kindCode);
  const base = name === null || name === "無し" ? kind ?? valueText(timetable.Line.Name) ?? "Japan mainline" : name;
  const number = valueText(stop.Number);
  return number === null || base.includes(number) ? base : `${base} ${number}`;
}

function boardStop(
  station: StationSnapshot,
  scheduledDeparture: string,
  platform: string | null,
  now: Date,
): StopSnapshot {
  return {
    stationId: station.id,
    stationName: station.name,
    countryCode: "JP",
    latitude: station.latitude,
    longitude: station.longitude,
    sequence: 1,
    scheduledArrival: null,
    scheduledDeparture,
    expectedArrival: null,
    expectedDeparture: null,
    plannedPlatform: platform,
    expectedPlatform: null,
    platformSource: platform === null ? null : sourceName,
    platformObservedAt: null,
    cancelled: false,
    passed: false,
  };
}

function lineName(value: EkispertTripLine): string {
  return valueText(value.Name) ?? "Japan mainline";
}

function tripStop(
  value: EkispertTripStop,
  sequence: number,
  serviceDate: string,
  reference: NativeReference,
  now: Date,
): StopSnapshot {
  const stationCode = value.Point.Station.code;
  const plannedPlatform = stationCode === reference.stationCode ? reference.platform : null;
  const scheduledArrival = clockTime(serviceDate, value.ArrivalState?.Datetime);
  const scheduledDeparture = clockTime(serviceDate, value.DepartureState?.Datetime);
  return {
    stationId: `jp:ekispert:${stationCode}`,
    stationName: value.Point.Station.Name,
    countryCode: "JP",
    latitude: null,
    longitude: null,
    sequence,
    scheduledArrival,
    scheduledDeparture,
    expectedArrival: null,
    expectedDeparture: null,
    plannedPlatform,
    expectedPlatform: null,
    platformSource: plannedPlatform === null ? null : sourceName,
    platformObservedAt: null,
    cancelled: false,
    passed: false,
  };
}

export class EkispertProvider implements RailProvider {
  readonly source = "ekispert" as const;
  readonly discoveryScope = "international" as const;
  private readonly stations = new Map<string, StationSnapshot>();

  constructor(
    private readonly apiKey: string,
    private readonly baseUrl = "https://api.ekispert.jp",
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
  ) {
    if (apiKey.trim().length === 0) throw new Error("Ekispert API key must not be empty");
  }

  async searchStations(query: string): Promise<StationSnapshot[]> {
    const unique = new Map<string, StationSnapshot>();
    for (const searchValue of ekispertSearchQueries(query)) {
      const payload = await this.request<EkispertStationResponse>("/v1/json/station", {
        name: searchValue,
        type: "train",
        gcs: "wgs84",
        limit: "30",
      });
      for (const point of values(payload.ResultSet.Point)) {
        if (stationType(point) !== "train") continue;
        const station = pointStation(point);
        unique.set(station.id, station);
        this.stations.set(station.nativeId, station);
      }
      if (unique.size > 0) break;
    }
    return [...unique.values()].slice(0, 20);
  }

  async fetchBoard(reference: BoardReference): Promise<BoardEntrySnapshot[]> {
    if (reference.direction === "arrivals") return [];
    const at = new Date(reference.at);
    const now = this.now();
    const serviceDate = japanDate(at);
    const overview = await this.request<EkispertTimetableResponse>("/v1/json/operationLine/timetable", {
      stationCode: reference.nativeId,
      date: compactDate(serviceDate),
    });
    const relevant = values(overview.ResultSet.TimeTable)
      .filter((value) => isJapanMainlineName(value.Line.Name))
      .slice(0, maximumDirectionTables);

    const station = this.stations.get(reference.nativeId) ?? {
      id: `jp:ekispert:${reference.nativeId}`,
      source: this.source,
      nativeId: reference.nativeId,
      name: values(overview.ResultSet.TimeTable)[0]?.Station?.Name ?? "Japan station",
      countryCode: "JP",
      latitude: 0,
      longitude: 0,
      operatorHints: ["JR", "Shinkansen", "Japan mainline rail"],
    } satisfies StationSnapshot;
    const entries: BoardEntrySnapshot[] = [];

    for (const direction of relevant) {
      const payload = await this.request<EkispertTimetableResponse>("/v1/json/operationLine/timetable", {
        stationCode: reference.nativeId,
        date: compactDate(serviceDate),
        code: direction.code,
      });
      const timetable = values(payload.ResultSet.TimeTable)[0];
      if (timetable === undefined) continue;
      const names = dictionary(timetable.LineName);
      const destinations = dictionary(timetable.LineDestination);
      const kinds = dictionary(timetable.LineKind);
      for (const hour of values(timetable.HourTable)) {
        const hourValue = valueText(hour.Hour);
        if (hourValue === null) continue;
        for (const minute of values(hour.MinuteTable)) {
          const minuteValue = valueText(minute.Minute);
          if (minuteValue === null) continue;
          const departure = scheduledTime(serviceDate, hourValue, minuteValue);
          for (const stop of values(minute.Stop)) {
            const platform = stop.platformNo?.trim() || null;
            const nativeId = encodeNativeReference({
              lineCode: stop.lineCode,
              stationCode: reference.nativeId,
              platform,
            });
            entries.push({
              trip: {
                id: `jp:ekispert:${nativeId}`,
                source: this.source,
                nativeId,
                serviceDate,
              },
              stop: boardStop(station, departure, platform, now),
              headsign: lookup(destinations, stop.destinationCode) ?? valueText(timetable.Line.Direction) ?? "",
              product: productName(timetable, stop, names, kinds),
            });
          }
        }
      }
    }

    const earliest = at.getTime() - 60_000;
    const latest = at.getTime() + 8 * 60 * 60_000;
    return entries
      .filter((entry) => {
        const departure = Date.parse(entry.stop.scheduledDeparture ?? "");
        return departure >= earliest && departure <= latest;
      })
      .sort((left, right) => Date.parse(left.stop.scheduledDeparture!) - Date.parse(right.stop.scheduledDeparture!))
      .slice(0, 30);
  }

  async fetchTrip(reference: CanonicalTripReference): Promise<TripSnapshot> {
    const native = decodeNativeReference(reference.nativeId);
    const payload = await this.request<EkispertTripResponse>("/v1/json/station/timetable/train", {
      code: native.lineCode,
    });
    const line = values(payload.ResultSet.Line)[0];
    if (line === undefined) throw new RailProviderNotFoundError();
    const now = this.now();
    const stops = values(line.Stop).map((stop, index) => tripStop(
      stop,
      index + 1,
      reference.serviceDate,
      native,
      now,
    ));
    return {
      ...reference,
      operatorName: "Japan Rail",
      product: lineName(line),
      headsign: stops.at(-1)?.stationName ?? "",
      fetchedAt: now.toISOString(),
      stops,
      alertIds: [],
    };
  }

  private async request<Response>(path: string, parameters: Record<string, string>): Promise<Response> {
    const url = new URL(path, this.baseUrl);
    url.search = new URLSearchParams({ key: this.apiKey, ...parameters }).toString();
    const response = await this.fetcher(url, { headers: { accept: "application/json" } });
    if (!response.ok) throw new Error(`Ekispert returned ${response.status}`);
    return response.json() as Promise<Response>;
  }
}
