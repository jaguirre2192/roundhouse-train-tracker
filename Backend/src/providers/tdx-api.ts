import { cachedLoad, ExpiringCache } from "./expiring-cache.js";
import type {
  TdxBoardRow, TdxDailyTimetable, TdxRailSystem, TdxStation, TraDailyBoard,
  TraDailyTrains, TraStationReport, TraTrainReport,
} from "./tdx-types.js";

function quoted(value: string): string { return "'" + value.replaceAll("'", "''") + "'"; }

export class TdxApi {
  private token: { value: Promise<string>; expiresAt: number } | undefined;
  private readonly responses = new ExpiringCache<Promise<unknown>>(200);

  constructor(
    private readonly clientId: string,
    private readonly clientSecret: string,
    private readonly baseUrl: string,
    private readonly tokenUrl: string,
    private readonly fetcher: typeof fetch,
    private readonly now: () => Date,
  ) {}

  async stations(system: TdxRailSystem): Promise<TdxStation[]> {
    const ttl = 6 * 60 * 60_000;
    const stations = system === "THSR"
      ? await this.get<TdxStation[]>("v2/Rail/THSR/Station", { $top: "500" }, ttl)
      : (await this.get<{ Stations: TdxStation[] }>("v3/Rail/TRA/Station", { $top: "500" }, ttl))?.Stations;
    if (!Array.isArray(stations)) throw new Error("TDX station directory unavailable");
    return stations;
  }

  async board(system: TdxRailSystem, station: string, date: string, today: string): Promise<TdxBoardRow[]> {
    const code = encodeURIComponent(station);
    if (system === "THSR") {
      const rows = await this.get<TdxBoardRow[]>(`v2/Rail/THSR/DailyTimetable/Station/${code}/${date}`, { $top: "500" });
      return rows.filter(row => row.TrainDate === date && row.StationID === station);
    }
    const route = date === today ? `Today/Station/${code}` : `TrainDate/${date}`;
    const data = await this.get<TraDailyBoard>(`v3/Rail/TRA/DailyStationTimetable/${route}`,
      date === today ? {} : { $filter: `StationID eq ${quoted(station)}` }, undefined, date);
    if (data.TrainDate !== date) return [];
    return data.StationTimetables.filter(group => group.StationID === station)
      .flatMap(group => group.TimeTables.map(row => ({
        ...row, TrainDate: date, StationID: station, StationName: group.StationName,
        EndingStationName: row.DestinationStationName ?? null,
      })));
  }

  async timetable(system: TdxRailSystem, train: string, date: string, today: string): Promise<TdxDailyTimetable | undefined> {
    const code = encodeURIComponent(train);
    if (system === "THSR") {
      const rows = await this.get<TdxDailyTimetable[]>(`v2/Rail/THSR/DailyTimetable/TrainNo/${code}/TrainDate/${date}`, {});
      return rows.find(row => row.TrainDate === date && row.DailyTrainInfo.TrainNo === train);
    }
    const route = date === today ? `Today/TrainNo/${code}` : `TrainDate/${date}`;
    const data = await this.get<TraDailyTrains>(`v3/Rail/TRA/DailyTrainTimetable/${route}`,
      date === today ? {} : { $filter: `TrainInfo/TrainNo eq ${quoted(train)}` }, undefined, date);
    if (data.TrainDate !== date) return undefined;
    const match = data.TrainTimetables.find(row => row.TrainInfo.TrainNo === train);
    return match && { TrainDate: date, DailyTrainInfo: match.TrainInfo, StopTimes: match.StopTimes };
  }

  async stationReports(filter: { station: string } | { train: string }): Promise<TraStationReport[]> {
    const path = "v3/Rail/TRA/StationLiveBoard";
    const data = "station" in filter
      ? await this.get<{ StationLiveBoards: TraStationReport[] }>(`${path}/Station/${encodeURIComponent(filter.station)}`, {}, 30_000)
      : await this.get<{ StationLiveBoards: TraStationReport[] }>(path, { $filter: `TrainNo eq ${quoted(filter.train)}` }, 30_000);
    return Array.isArray(data?.StationLiveBoards) ? data.StationLiveBoards : [];
  }

  async trainReports(train: string): Promise<TraTrainReport[]> {
    const data = await this.get<{ TrainLiveBoards: TraTrainReport[] }>(
      `v3/Rail/TRA/TrainLiveBoard/TrainNo/${encodeURIComponent(train)}`, {}, 30_000);
    return Array.isArray(data?.TrainLiveBoards) ? data.TrainLiveBoards : [];
  }

  private get<T>(path: string, query: Record<string, string>, ttl = 5 * 60_000, serviceDate = ""): Promise<T> {
    const url = new URL(path, this.baseUrl.replace(/\/?$/u, "/"));
    url.search = new URLSearchParams({ ...query, $format: "JSON" }).toString();
    // "Today" URLs keep their spelling when the operator's service date changes.
    const key = serviceDate ? url.href + "#" + serviceDate : url.href;
    return cachedLoad(this.responses, key, this.now().getTime(), ttl, () => this.fetchJSON(url)) as Promise<T>;
  }

  private async fetchJSON(url: URL): Promise<unknown> {
    const response = await this.fetcher(url, {
      headers: { accept: "application/json", authorization: `Bearer ${await this.accessToken()}` },
      signal: AbortSignal.timeout(12_000),
    });
    if (!response.ok) throw new Error(`TDX returned ${response.status}`);
    return response.json();
  }

  private accessToken(): Promise<string> {
    const now = this.now().getTime();
    if (this.token && this.token.expiresAt > now) return this.token.value;
    const entry = { expiresAt: Infinity, value: this.requestToken().then(token => {
      entry.expiresAt = this.now().getTime() + Math.max(0, token.expires_in - 60) * 1_000;
      return token.access_token;
    }) };
    this.token = entry;
    void entry.value.catch(() => { if (this.token === entry) this.token = undefined; });
    return entry.value;
  }

  private async requestToken(): Promise<{ access_token: string; expires_in: number }> {
    const response = await this.fetcher(this.tokenUrl, {
      method: "POST",
      headers: { accept: "application/json", "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ grant_type: "client_credentials", client_id: this.clientId, client_secret: this.clientSecret }),
      signal: AbortSignal.timeout(12_000),
    });
    if (!response.ok) throw new Error(`TDX authorization returned ${response.status}`);
    const token = await response.json() as { access_token?: string; expires_in?: number };
    if (!token.access_token || typeof token.expires_in !== "number" || !Number.isFinite(token.expires_in) || token.expires_in <= 0) {
      throw new Error("TDX did not return a usable access token");
    }
    return { access_token: token.access_token, expires_in: token.expires_in };
  }
}
