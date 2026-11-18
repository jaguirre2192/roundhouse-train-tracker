import type { BoardEntrySnapshot, BoardReference, StationSnapshot } from "../domain/discovery.js";
import type { CanonicalTripReference, TripSnapshot } from "../domain/snapshot.js";
import { RailProviderNotFoundError, type RailProvider } from "./provider.js";
import { TdxApi } from "./tdx-api.js";
import { applyTraStationReports, applyTraTrainReports, traTripMayBeRunning } from "./tdx-live.js";
import type { TdxRailSystem } from "./tdx-types.js";
import {
  isIntercityTdxService, parseTdxNativeID, taiwanDate, tdxName, tdxNativeID, tdxProduct,
  tdxStationPosition, tdxStops,
} from "./tdx-values.js";

const railSystems: TdxRailSystem[] = ["THSR", "TRA"];
const operators = { THSR: "Taiwan High Speed Rail", TRA: "Taiwan Railway Corporation" } as const;

function queryKey(value: string): string {
  return value.normalize("NFKD").replace(/\p{Diacritic}/gu, "").trim().toLowerCase();
}

export class TdxProvider implements RailProvider {
  readonly source = "tdx" as const;
  readonly discoveryScope = "international" as const;
  private readonly api: TdxApi;

  constructor(
    clientId: string,
    clientSecret: string,
    baseUrl = "https://tdx.transportdata.tw/api/basic",
    tokenUrl = "https://tdx.transportdata.tw/auth/realms/TDXConnect/protocol/openid-connect/token",
    fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
  ) {
    this.api = new TdxApi(clientId, clientSecret, baseUrl, tokenUrl, fetcher, now);
  }

  async searchStations(query: string): Promise<StationSnapshot[]> {
    const needle = queryKey(query);
    if (needle.length < 2) return [];
    const results = await Promise.allSettled(railSystems.map(async system => {
      const stations = await this.api.stations(system);
      return stations.flatMap(station => {
        const position = tdxStationPosition(station);
        const names = [station.StationName.En, station.StationName.Zh_tw, station.StationID];
        if (!position || !names.some(name => name && queryKey(name).includes(needle))) return [];
        const nativeId = tdxNativeID(system, station.StationID);
        return [{
          id: `tw:tdx:${nativeId}`, source: this.source, nativeId, name: tdxName(station.StationName),
          countryCode: "TW", latitude: position.PositionLat, longitude: position.PositionLon, operatorHints: [operators[system]],
        }];
      });
    }));
    if (results.every(result => result.status === "rejected")) throw results[0]!.reason;
    return results.flatMap(result => result.status === "fulfilled" ? result.value : []).slice(0, 20);
  }

  async fetchBoard(reference: BoardReference): Promise<BoardEntrySnapshot[]> {
    const { system, value: stationId } = parseTdxNativeID(reference.nativeId);
    const at = new Date(reference.at), now = this.now();
    const date = taiwanDate(at), today = taiwanDate(now);
    const [schedule, reports] = await Promise.all([
      this.api.board(system, stationId, date, today),
      system === "TRA" && date === today ? this.api.stationReports({ station: stationId }).catch(() => []) : [],
    ]);
    const departing = reference.direction === "departures";
    const entries = schedule.filter(value => isIntercityTdxService(system, value)).flatMap(value => {
      const [planned] = tdxStops(system, date, [{ ...value, StopSequence: 1 }], []);
      const stop = applyTraStationReports(planned!, value, value.TrainNo, reports, now);
      const event = departing ? stop.expectedDeparture ?? stop.scheduledDeparture : stop.expectedArrival ?? stop.scheduledArrival;
      if (!event || Date.parse(event) < at.getTime() - 5 * 60_000) return [];
      const nativeId = tdxNativeID(system, value.TrainNo);
      return [{ time: Date.parse(event), entry: {
        trip: { id: `tw:tdx:${nativeId}`, source: this.source, nativeId, serviceDate: date },
        stop, headsign: tdxName(value.EndingStationName), product: tdxProduct(system, value),
      } }];
    });
    return entries.sort((left, right) => left.time - right.time).slice(0, 30).map(item => item.entry);
  }

  async fetchTrip(reference: CanonicalTripReference, options: { includeStationCoordinates?: boolean } = {}): Promise<TripSnapshot> {
    const { system, value: train } = parseTdxNativeID(reference.nativeId);
    const now = this.now();
    const timetable = await this.api.timetable(system, train, reference.serviceDate, taiwanDate(now));
    if (!timetable) throw new RailProviderNotFoundError();
    const stations = options.includeStationCoordinates === false ? [] : await this.api.stations(system).catch(() => []);
    const info = timetable.DailyTrainInfo;
    const stops = tdxStops(system, reference.serviceDate, timetable.StopTimes, stations, info.SuspendedFlag === 1);
    const snapshot: TripSnapshot = {
      ...reference, operatorName: operators[system], product: tdxProduct(system, info),
      headsign: tdxName(info.EndingStationName) || stops.at(-1)?.stationName || "",
      fetchedAt: now.toISOString(), stops, alertIds: [],
    };
    if (system !== "TRA" || info.SuspendedFlag === 1 || !traTripMayBeRunning(stops, now)) return snapshot;
    const [board, movement] = await Promise.all([
      this.api.stationReports({ train }).catch(() => []),
      this.api.trainReports(train).catch(() => []),
    ]);
    const callClocks = new Map(timetable.StopTimes.map(call => [call.StopSequence, call]));
    snapshot.stops = stops.map(stop => {
      const call = callClocks.get(stop.sequence);
      return call && stop.stationId === `tw:tdx:${tdxNativeID(system, call.StationID)}`
        ? applyTraStationReports(stop, call, train, board, now) : stop;
    });
    return applyTraTrainReports(snapshot, train, movement, now);
  }
}
