import gtfsRealtime, { type transit_realtime } from "gtfs-realtime-bindings";
import type { TripSnapshot, VehiclePositionSnapshot } from "../domain/snapshot.js";
import type { TripPositionOverlay } from "./trip-position-overlay.js";
import type { RegionalRailIndex } from "./trafiklab-regional-index.js";
import { matchRegionalRailTrip } from "./trafiklab-regional-matching.js";
import type { RegionalCachedFeed } from "./trafiklab-regional-realtime.js";

const gtfs = gtfsRealtime.transit_realtime;
const maximumBodyBytes = 2 * 1_024 * 1_024;
const maximumCachedBytes = 96 * 1_024;

export interface RegionalPositionCallbacks {
  reservePositionRequest: () => Promise<boolean>;
  readPositionFeed?: () => Promise<RegionalCachedFeed | null>;
  writePositionFeed?: (value: RegionalCachedFeed) => Promise<void>;
}

interface Options extends RegionalPositionCallbacks {
  index: RegionalRailIndex;
  minimumFetchIntervalMilliseconds?: number;
  fetcher?: typeof fetch;
  now?: () => Date;
}

function timestamp(value: unknown): number | null {
  const seconds = Number(value);
  return Number.isFinite(seconds) && seconds > 0 && Number.isFinite(new Date(seconds * 1_000).getTime()) ? seconds * 1_000 : null;
}

function fresh(value: number | null, now: number): value is number {
  return value !== null && now - value <= 300_000 && value - now <= 120_000;
}

async function boundedBody(response: Response): Promise<Uint8Array> {
  if (Number(response.headers.get("content-length")) > maximumBodyBytes) {
    await response.body?.cancel(); throw new Error("Regional position feed exceeds byte cap");
  }
  const reader = response.body?.getReader();
  if (reader === undefined) throw new Error("Regional position feed has no body");
  const chunks: Uint8Array[] = []; let length = 0;
  for (;;) {
    const { value, done } = await reader.read(); if (done) break;
    length += value.byteLength;
    if (length > maximumBodyBytes) { await reader.cancel(); throw new Error("Regional position feed exceeds byte cap"); }
    chunks.push(value);
  }
  const bytes = new Uint8Array(length); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return bytes;
}

/** Uses publisher GPS only after the complete national-to-regional rail join. */
export class TrafiklabRegionalPositionOverlay implements TripPositionOverlay {
  readonly sourceName = "Trafiklab GTFS Regional — Skåne rail GPS";
  readonly supportedCountryCodes = new Set(["SE"]);
  private readonly fetcher: typeof fetch;
  private readonly now: () => Date;
  private readonly interval: number;
  private readonly tripIds: ReadonlySet<string>;
  private cache: { expiresAt: number; value: Promise<transit_realtime.FeedMessage | null> } | null = null;
  private readonly diagnostics = {
    outcome: "not-requested", cacheOrigin: "none", fetchedAt: null as number | null,
    headerAt: null as string | null, railEntityCount: 0, httpStatus: null as number | null,
    cacheWriteOutcome: "not-attempted", observations: 0,
  };

  constructor(private readonly apiKey: string, private readonly options: Options) {
    this.fetcher = options.fetcher ?? ((input, init) => fetch(input, init));
    this.now = options.now ?? (() => new Date());
    const interval = options.minimumFetchIntervalMilliseconds;
    this.interval = interval !== undefined && Number.isFinite(interval) ? Math.max(30_000, interval) : 240_000;
    this.tripIds = new Set(options.index.trips.map((trip) => trip[0]));
  }

  health() { return { ...this.diagnostics }; }

  async positionUpdates(snapshot: TripSnapshot): Promise<VehiclePositionSnapshot[]> {
    this.diagnostics.observations = 0;
    if (this.options.index.operator !== "skane") return [];
    const match = matchRegionalRailTrip(snapshot, this.options.index, this.now());
    if (match === null) return [];
    const feed = await this.feed(); const now = this.now().getTime();
    if (feed === null || !fresh(timestamp(feed.header.timestamp), now)) return [];
    const candidates = feed.entity.flatMap((entity) => entity.vehicle?.trip?.tripId === match.trip[0] ? [entity.vehicle] : []);
    if (candidates.length !== 1) return [];
    const vehicle = candidates[0]!;
    const date = vehicle.trip?.startDate?.trim();
    if (date && date !== snapshot.serviceDate.replaceAll("-", "")) return [];
    // Skåne omits startDate in its GPS descriptors. The static service-date join
    // plus a publisher observation inside this dated journey's window supplies
    // that missing context; neither the wall clock nor feed header invents it.
    const asOf = Object.hasOwn(vehicle, "timestamp") ? timestamp(vehicle.timestamp) : null;
    const scheduled = snapshot.stops.flatMap((stop) => [stop.scheduledArrival, stop.scheduledDeparture])
      .flatMap((value) => value === null || !Number.isFinite(Date.parse(value)) ? [] : [Date.parse(value)]);
    if (!fresh(asOf, now) || scheduled.length < 2 || asOf < Math.min(...scheduled) - 900_000
      || asOf > Math.max(...scheduled) + 900_000) return [];
    const position = vehicle.position;
    if (position == null || !Object.hasOwn(position, "latitude") || !Object.hasOwn(position, "longitude")) return [];
    const latitude = Number(position.latitude), longitude = Number(position.longitude);
    if (!Number.isFinite(latitude) || !Number.isFinite(longitude) || Math.abs(latitude) > 90
      || Math.abs(longitude) > 180 || (latitude === 0 && longitude === 0)) return [];
    const bearing = Object.hasOwn(position, "bearing") ? Number(position.bearing) : Number.NaN;
    this.diagnostics.observations = 1;
    return [{ latitude, longitude, heading: Number.isFinite(bearing) && bearing >= 0 && bearing <= 360 ? bearing : null,
      source: "real", confidence: now - asOf < 90_000 ? 1 : 0.8, asOf: new Date(asOf).toISOString(), provider: this.sourceName }];
  }

  private feed(): Promise<transit_realtime.FeedMessage | null> {
    const now = this.now().getTime();
    if (this.cache !== null && now < this.cache.expiresAt) return this.cache.value;
    const entry = { expiresAt: now + this.interval, value: Promise.resolve<transit_realtime.FeedMessage | null>(null) };
    entry.value = this.loadFeed(entry); this.cache = entry; return entry.value;
  }

  private async loadFeed(entry: { expiresAt: number }): Promise<transit_realtime.FeedMessage | null> {
    const health = this.diagnostics;
    health.outcome = "loading"; health.cacheOrigin = "none"; health.fetchedAt = null;
    health.headerAt = null; health.railEntityCount = 0; health.httpStatus = null; health.cacheWriteOutcome = "not-attempted";
    try {
      const stored = await this.options.readPositionFeed?.().catch(() => null);
      const now = this.now().getTime();
      if (stored != null && Number.isFinite(stored.fetchedAt) && stored.fetchedAt > 0
        && now >= stored.fetchedAt && now - stored.fetchedAt < this.interval
        && stored.bytes instanceof Uint8Array && stored.bytes.byteLength > 0 && stored.bytes.byteLength <= maximumCachedBytes) {
        try {
          const feed = this.decode(stored.bytes);
          if (feed !== null) {
            entry.expiresAt = stored.fetchedAt + this.interval; health.cacheOrigin = "persistent";
            health.fetchedAt = stored.fetchedAt; return feed;
          }
        } catch { /* Invalid persisted bytes never bypass the quota gate. */ }
      }
      if (!await this.options.reservePositionRequest()) {
        // No request was spent. Use the configured lane cadence for Silver,
        // retaining the original two-minute Bronze denial retry by default.
        entry.expiresAt = this.now().getTime() + Math.min(120_000, this.interval); health.outcome = "quota-denied"; return null;
      }
      const url = new URL(`https://opendata.samtrafiken.se/gtfs-rt/${this.options.index.operator}/VehiclePositions.pb`);
      url.searchParams.set("key", this.apiKey);
      const response = await this.fetcher(url, { headers: { accept: "application/x-protobuf" }, signal: AbortSignal.timeout(2_500) });
      health.httpStatus = response.status;
      if (!response.ok) { await response.body?.cancel(); health.outcome = "http-error"; return null; }
      const feed = this.decode(await boundedBody(response));
      if (feed === null) return null;
      const fetchedAt = this.now().getTime(); health.cacheOrigin = "network"; health.fetchedAt = fetchedAt;
      if (this.options.writePositionFeed !== undefined) {
        const bytes = gtfs.FeedMessage.encode(feed).finish();
        if (bytes.byteLength > maximumCachedBytes) health.cacheWriteOutcome = "too-large";
        else {
          try { await this.options.writePositionFeed({ fetchedAt, bytes }); health.cacheWriteOutcome = "stored"; }
          catch { health.cacheWriteOutcome = "error"; }
        }
      }
      return feed;
    } catch { health.outcome = "error"; return null; }
  }

  private decode(bytes: Uint8Array): transit_realtime.FeedMessage | null {
    const feed = gtfs.FeedMessage.decode(bytes);
    const generated = timestamp(feed.header.timestamp);
    this.diagnostics.headerAt = generated === null ? null : new Date(generated).toISOString();
    if (!fresh(generated, this.now().getTime())) { this.diagnostics.outcome = "stale-header"; return null; }
    feed.entity = feed.entity.filter((entity) => this.tripIds.has(entity.vehicle?.trip?.tripId ?? ""));
    this.diagnostics.railEntityCount = feed.entity.length; this.diagnostics.outcome = "ok"; return feed;
  }
}
