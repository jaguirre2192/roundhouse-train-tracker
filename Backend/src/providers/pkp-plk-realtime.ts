import type { TripSnapshot } from "../domain/snapshot.js";
import { cachedLoad, ExpiringCache } from "./expiring-cache.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";
import {
  matchingPLKOperation,
  matchingPLKRoute,
  parsePLKDateTime,
  plkAnchorStationIDs,
  projectPLKRealtime,
  type MatchedPLKRoute,
} from "./pkp-plk-mapper.js";
import type {
  PLKDisruptionsResponse,
  PLKOperationsResponse,
  PLKScheduleResponse,
  PLKStation,
  PLKStationsResponse,
} from "./pkp-plk-types.js";

const defaultBaseURL = "https://pdp-api.plk-sa.pl/api/v1";

interface RouteContext {
  anchorIds: number[];
  schedule: PLKScheduleResponse;
  matched: MatchedPLKRoute;
}

export class PKPPLKRealtimeOverlay implements PlatformRealtimeOverlay {
  readonly sourceName = "PKP PLK Open Data";
  readonly supportedCountryCodes = new Set(["PL"]);
  private stationsCache: { loadedAt: number; value: Promise<PLKStation[]> } | null = null;
  private readonly scheduleCache = new ExpiringCache<Promise<PLKScheduleResponse>>(200);
  private operationsCache: { loadedAt: number; value: Promise<PLKOperationsResponse> } | null = null;
  private readonly disruptionsCache = new ExpiringCache<Promise<PLKDisruptionsResponse>>(200);
  private readonly contextCache = new ExpiringCache<Promise<RouteContext | null>>(500);

  constructor(
    private readonly apiKey: string,
    private readonly baseURL = defaultBaseURL,
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
  ) {}

  async platformUpdates(snapshot: TripSnapshot): Promise<PlatformObservation[]> {
    const context = await this.context(snapshot);
    if (context === null) return [];
    // Operations and disruptions are independent: a slow optional alert feed
    // must not hold up available platforms, delays, or cancellations.
    const operations = await this.operations().catch(() => null);
    const operation = operations === null ? null
      : matchingPLKOperation(context.matched.route, snapshot.serviceDate, operations.trains ?? []);
    const observedAt = parsePLKDateTime(operations === null
      ? context.schedule.generatedAt : operations.generatedAt) ?? this.now().toISOString();
    return projectPLKRealtime(snapshot, context.matched, operation, [], observedAt, this.sourceName).observations;
  }

  async tripAlertIds(snapshot: TripSnapshot): Promise<string[]> {
    const context = await this.context(snapshot);
    if (context === null) return [];
    const disruptions = await this.disruptions(snapshot.serviceDate, context.anchorIds).catch(() => null);
    return projectPLKRealtime(
      snapshot, context.matched, null, disruptions?.disruptions ?? [],
      parsePLKDateTime(context.schedule.generatedAt) ?? this.now().toISOString(), this.sourceName,
    ).alertIds;
  }

  private context(snapshot: TripSnapshot): Promise<RouteContext | null> {
    const now = this.now().getTime();
    return cachedLoad(this.contextCache, snapshot.id, now, 18_000, () => this.loadContext(snapshot));
  }

  private async loadContext(snapshot: TripSnapshot): Promise<RouteContext | null> {
    const polishStops = snapshot.stops.filter((stop) => stop.countryCode === "PL");
    if (polishStops.length === 0) return null;
    const anchorIds = plkAnchorStationIDs(await this.stations(), polishStops);
    if (anchorIds.length === 0) return null;
    const operatingDate = snapshot.serviceDate;
    const schedule = await this.schedule(operatingDate, anchorIds);
    const matched = matchingPLKRoute(snapshot, schedule, operatingDate);
    return matched === null ? null : { anchorIds, schedule, matched };
  }

  private stations(): Promise<PLKStation[]> {
    const now = this.now().getTime();
    if (this.stationsCache !== null && now - this.stationsCache.loadedAt < 24 * 60 * 60_000) {
      return this.stationsCache.value;
    }
    const value = this.json<PLKStationsResponse>("dictionaries/stations?pageSize=10000")
      .then((response) => response.stations ?? []);
    this.stationsCache = { loadedAt: now, value };
    return value;
  }

  private schedule(date: string, stationIds: number[]): Promise<PLKScheduleResponse> {
    const anchor = stationIds.join(",");
    const key = `${date}:${anchor}`;
    const now = this.now().getTime();
    const filter = stationIds.length >= 2
      ? `fromStations=${stationIds[0]}&toStations=${stationIds.at(-1)}`
      : `stations=${stationIds[0]}`;
    return cachedLoad(this.scheduleCache, key, now, 6 * 60 * 60_000, () => this.json<PLKScheduleResponse>(
      `schedules?dateFrom=${date}&dateTo=${date}&${filter}&fullRoute=true&dictionaries=true`,
    ));
  }

  private operations(): Promise<PLKOperationsResponse> {
    const now = this.now().getTime();
    if (this.operationsCache !== null && now - this.operationsCache.loadedAt < 30_000) {
      return this.operationsCache.value;
    }
    const value = this.json<PLKOperationsResponse>("operations?fullRoutes=true&withPlanned=true&pageSize=5000");
    this.operationsCache = { loadedAt: now, value };
    return value;
  }

  private disruptions(date: string, stationIds: number[]): Promise<PLKDisruptionsResponse> {
    const key = `${date}:${stationIds.join(",")}`;
    const now = this.now().getTime();
    return cachedLoad(this.disruptionsCache, key, now, 60_000, () => this.json<PLKDisruptionsResponse>(
      `disruptions?dateFrom=${date}&dateTo=${date}&stations=${stationIds.join(",")}&dictionaries=false`,
    ));
  }

  private async json<Response>(path: string): Promise<Response> {
    const response = await this.fetcher(new URL(path, `${this.baseURL}/`), {
      headers: {
        accept: "application/json",
        "X-API-Key": this.apiKey,
        "user-agent": "TrainTracker/0.4 (+https://github.com/jaguirre2192)",
      },
      signal: AbortSignal.timeout(12_000),
    });
    if (!response.ok) throw new Error(`PKP PLK Open Data returned ${response.status}`);
    return response.json() as Promise<Response>;
  }
}
