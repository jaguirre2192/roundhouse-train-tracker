import gtfsRealtime, { type transit_realtime } from "gtfs-realtime-bindings";
import type { TripSnapshot } from "../domain/snapshot.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";
import { needsRealtimeUpdate } from "./realtime-stop-candidates.js";
import type { RegionalRailCall, RegionalRailIndex, RegionalRailStation } from "./trafiklab-regional-index.js";
import { matchRegionalRailTrip } from "./trafiklab-regional-matching.js";

const gtfs = gtfsRealtime.transit_realtime;
const maximumBodyBytes = 2 * 1_024 * 1_024;
const maximumCachedFeedBytes = 96 * 1_024;

export interface RegionalCachedFeed { fetchedAt: number; bytes: Uint8Array }
interface ResolvedFeed { fetchedAt: number; feed: transit_realtime.FeedMessage }

export interface TrafiklabRegionalOptions {
  index: RegionalRailIndex;
  // The owner reserves a key-wide request before network activity. Production
  // uses persistent quota state; there is deliberately no permissive fallback.
  reserveRequest: () => Promise<boolean>;
  readFeed?: () => Promise<RegionalCachedFeed | null>;
  writeFeed?: (value: RegionalCachedFeed) => Promise<void>;
  minimumFetchIntervalMilliseconds?: number;
  fetcher?: typeof fetch;
  now?: () => Date;
}

interface RegionalFeedHealth {
  lastAttemptAt: string | null;
  quotaGranted: boolean | null;
  outcome: "not-requested" | "reserving" | "quota-denied" | "fetching" | "http-error" | "missing-header" | "stale-header" | "future-header" | "ok" | "error";
  errorPhase: "quota" | "fetch" | "decode" | null;
  httpStatus: number | null;
  headerAt: string | null;
  entityCount: number | null;
  railEntityCount: number | null;
  matchOutcome: "not-checked" | "no-static-match" | "no-feed" | "no-realtime-match" | "stale-observation" | "observed";
  observations: number;
  cacheOrigin: "none" | "network" | "persistent";
  fetchedAt: number | null;
  cacheReadOutcome: "not-configured" | "missing" | "invalid" | "accepted" | "error";
  cacheWriteOutcome: "not-attempted" | "stored" | "too-large" | "error";
}

function timestamp(value: unknown): Date | null {
  const seconds = Number(value);
  const date = new Date(seconds * 1_000);
  return Number.isFinite(seconds) && seconds > 0 && Number.isFinite(date.getTime()) ? date : null;
}

function expectedTime(event: transit_realtime.TripUpdate.IStopTimeEvent | null | undefined, scheduled: string | null): string | undefined {
  if (event === null || event === undefined || scheduled === null) return undefined;
  const absolute = Object.hasOwn(event, "time") ? timestamp(event.time) : null;
  const delay = Object.hasOwn(event, "delay") ? Number(event.delay) : undefined;
  if (absolute !== null) {
    // When both fields exist, independently verify the publisher's base time.
    if (delay !== undefined && (!Number.isFinite(delay)
      || Math.abs(absolute.getTime() - delay * 1_000 - Date.parse(scheduled)) > 1_000)) return undefined;
    return absolute.toISOString();
  }
  if (delay === undefined || !Number.isFinite(delay)) return undefined;
  const value = new Date(Date.parse(scheduled) + delay * 1_000);
  return Number.isFinite(value.getTime()) ? value.toISOString() : undefined;
}

async function boundedBody(response: Response): Promise<Uint8Array> {
  if (Number(response.headers.get("content-length")) > maximumBodyBytes) {
    await response.body?.cancel();
    throw new Error("Trafiklab Regional feed exceeds byte limit");
  }
  if (response.body === null) throw new Error("Trafiklab Regional feed has no body");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maximumBodyBytes) {
      await reader.cancel();
      throw new Error("Trafiklab Regional feed exceeds byte limit");
    }
    chunks.push(value);
  }
  const body = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { body.set(chunk, offset); offset += chunk.byteLength; }
  return body;
}

export class TrafiklabRegionalRealtimeOverlay implements PlatformRealtimeOverlay {
  readonly sourceName = "Trafiklab GTFS Regional — Skåne rail";
  readonly supportedCountryCodes = new Set(["SE"]);
  private readonly index: RegionalRailIndex;
  private readonly stations: ReadonlyMap<string, RegionalRailStation>;
  private readonly tripIds: ReadonlySet<string>;
  private readonly fetcher: typeof fetch;
  private readonly now: () => Date;
  private readonly minimumFetchInterval: number;
  private cache: { expiresAt: number; value: Promise<transit_realtime.FeedMessage | null> } | null = null;
  private readonly diagnostics: RegionalFeedHealth = { lastAttemptAt: null, quotaGranted: null, outcome: "not-requested", errorPhase: null,
    httpStatus: null, headerAt: null, entityCount: null, railEntityCount: null, matchOutcome: "not-checked", observations: 0,
    cacheOrigin: "none", fetchedAt: null, cacheReadOutcome: "not-configured", cacheWriteOutcome: "not-attempted" };

  constructor(private readonly apiKey: string, private readonly options: TrafiklabRegionalOptions) {
    this.index = options.index;
    this.stations = new Map(this.index.stations.map((station) => [station[0], station]));
    this.tripIds = new Set(this.index.trips.map((trip) => trip[0]));
    this.fetcher = options.fetcher ?? ((input, init) => fetch(input, init));
    this.now = options.now ?? (() => new Date());
    const interval = options.minimumFetchIntervalMilliseconds;
    this.minimumFetchInterval = interval !== undefined && Number.isFinite(interval) ? Math.max(30_000, interval) : 240_000;
  }

  health(): RegionalFeedHealth { return { ...this.diagnostics }; }

  async platformUpdates(snapshot: TripSnapshot): Promise<PlatformObservation[]> {
    this.diagnostics.observations = 0;
    const match = matchRegionalRailTrip(snapshot, this.index, this.now());
    if (match === null) { this.diagnostics.matchOutcome = "no-static-match"; return []; }
    this.diagnostics.matchOutcome = "no-feed";
    const feed = await this.feed();
    if (feed === null) return [];
    const headerTime = timestamp(feed.header.timestamp);
    if (headerTime === null || this.now().getTime() - headerTime.getTime() > 5 * 60_000
      || headerTime.getTime() - this.now().getTime() > 120_000) return [];
    const updates = feed.entity.flatMap((entity) => entity.tripUpdate?.trip.tripId === match.trip[0]
      && entity.tripUpdate.trip.startDate === snapshot.serviceDate.replaceAll("-", "") ? [entity.tripUpdate] : []);
    if (updates.length !== 1) { this.diagnostics.matchOutcome = "no-realtime-match"; return []; }
    const update = updates[0]!;
    const observedAt = timestamp(update.timestamp) ?? timestamp(feed.header.timestamp);
    if (observedAt === null || this.now().getTime() - observedAt.getTime() > 5 * 60_000
      || observedAt.getTime() - this.now().getTime() > 120_000) { this.diagnostics.matchOutcome = "stale-observation"; return []; }
    const cancelled = update.trip.scheduleRelationship === gtfs.TripDescriptor.ScheduleRelationship.CANCELED
      || update.trip.scheduleRelationship === gtfs.TripDescriptor.ScheduleRelationship.DELETED;
    const observations = snapshot.stops.flatMap((stop): PlatformObservation[] => {
      const call = match.calls.get(stop.sequence);
      if (call === undefined || !needsRealtimeUpdate(stop, snapshot)) return [];
      const candidates = (update.stopTimeUpdate ?? []).filter((value) => this.matchesCall(value, call));
      if (candidates.length !== 1 && !(cancelled && (update.stopTimeUpdate ?? []).length === 0)) return [];
      const live = candidates[0];
      if (!cancelled && live?.scheduleRelationship === gtfs.TripUpdate.StopTimeUpdate.ScheduleRelationship.NO_DATA) return [];
      const liveStation = live?.stopId ? this.stations.get(live.stopId) : undefined;
      const expectedArrival = expectedTime(live?.arrival, stop.scheduledArrival);
      const expectedDeparture = expectedTime(live?.departure, stop.scheduledDeparture);
      const expectedPlatform = liveStation?.[5] || undefined;
      const stopCancelled = cancelled || live?.scheduleRelationship === gtfs.TripUpdate.StopTimeUpdate.ScheduleRelationship.SKIPPED;
      if (expectedArrival === undefined && expectedDeparture === undefined && expectedPlatform === undefined && !stopCancelled) return [];
      return [{
        stopSequence: stop.sequence, stationId: stop.stationId,
        expectedArrival, expectedDeparture, expectedPlatform,
        cancelled: stopCancelled, observedAt: observedAt.toISOString(), source: this.sourceName,
      }];
    });
    this.diagnostics.matchOutcome = "observed"; this.diagnostics.observations = observations.length;
    return observations;
  }

  private matchesCall(update: transit_realtime.TripUpdate.IStopTimeUpdate, call: RegionalRailCall): boolean {
    const sequence = Object.hasOwn(update, "stopSequence") ? Number(update.stopSequence) : undefined;
    if (sequence !== undefined && sequence !== call[1]) return false;
    const stopId = update.stopId?.trim();
    if (stopId) {
      const actual = this.stations.get(stopId);
      if (actual === undefined || actual[1] !== this.index.stations[call[0]]?.[1]) return false;
    }
    return sequence !== undefined || Boolean(stopId);
  }

  private feed(): Promise<transit_realtime.FeedMessage | null> {
    const now = this.now().getTime();
    if (this.cache !== null && now < this.cache.expiresAt) return this.cache.value;
    const entry = { expiresAt: now + this.minimumFetchInterval, value: Promise.resolve<transit_realtime.FeedMessage | null>(null) };
    entry.value = this.loadFeed().then((value) => {
      // Loading persisted bytes must not restart their original cache lifetime.
      if (value !== null) entry.expiresAt = value.fetchedAt + this.minimumFetchInterval;
      // A denial spends no request. Bronze retries on its two-minute stagger;
      // Silver retries at the shorter lane interval, with the gate authoritative.
      else if (this.diagnostics.outcome === "quota-denied") entry.expiresAt = this.now().getTime() + Math.min(120_000, this.minimumFetchInterval);
      return value?.feed ?? null;
    });
    // Failures also consume quota. Keep the cooldown and share in-flight work.
    this.cache = entry;
    return entry.value;
  }

  private async loadFeed(): Promise<ResolvedFeed | null> {
    const health = this.diagnostics;
    health.lastAttemptAt = this.now().toISOString(); health.quotaGranted = null; health.outcome = "reserving"; health.errorPhase = null;
    health.httpStatus = null; health.headerAt = null; health.entityCount = null; health.railEntityCount = null;
    health.cacheOrigin = "none"; health.fetchedAt = null; health.cacheWriteOutcome = "not-attempted";
    const persisted = await this.readPersistedFeed();
    if (persisted !== null) return persisted;
    // Rejected persisted metadata must not masquerade as the next attempt.
    health.headerAt = null; health.entityCount = null; health.railEntityCount = null; health.outcome = "reserving";
    let phase: "quota" | "fetch" | "decode" = "quota";
    try {
      if (this.index.operator !== "skane") return null;
      health.quotaGranted = await this.options.reserveRequest();
      if (!health.quotaGranted) { health.outcome = "quota-denied"; return null; }
      phase = "fetch"; health.outcome = "fetching";
      const url = new URL(`https://opendata.samtrafiken.se/gtfs-rt/${this.index.operator}/TripUpdates.pb`);
      url.searchParams.set("key", this.apiKey);
      const response = await this.fetcher(url, {
        headers: { accept: "application/x-protobuf", "user-agent": "TrainTracker/0.4 (+https://github.com/jaguirre2192)" },
        signal: AbortSignal.timeout(8_000),
      });
      health.httpStatus = response.status;
      if (!response.ok) {
        health.outcome = "http-error";
        await response.body?.cancel();
        throw new Error(`Trafiklab Regional TripUpdates returned ${response.status}`);
      }
      phase = "decode";
      const feed = this.decodeFreshRailFeed(await boundedBody(response));
      if (feed === null) return null;
      const fetchedAt = this.now().getTime();
      health.cacheOrigin = "network"; health.fetchedAt = fetchedAt;
      if (this.options.writeFeed !== undefined) {
        const bytes = gtfs.FeedMessage.encode(feed).finish();
        if (bytes.byteLength > maximumCachedFeedBytes) health.cacheWriteOutcome = "too-large";
        else {
          try { await this.options.writeFeed({ fetchedAt, bytes }); health.cacheWriteOutcome = "stored"; }
          catch { health.cacheWriteOutcome = "error"; }
        }
      }
      return { feed, fetchedAt };
    } catch (error) {
      health.errorPhase = phase;
      if (health.outcome !== "http-error") health.outcome = "error";
      throw error;
    }
  }

  private async readPersistedFeed(): Promise<ResolvedFeed | null> {
    const health = this.diagnostics;
    if (this.options.readFeed === undefined) { health.cacheReadOutcome = "not-configured"; return null; }
    try {
      const value = await this.options.readFeed();
      if (value === null) { health.cacheReadOutcome = "missing"; return null; }
      const age = this.now().getTime() - value.fetchedAt;
      if (!Number.isFinite(value.fetchedAt) || value.fetchedAt <= 0 || age < 0 || age >= this.minimumFetchInterval
        || !(value.bytes instanceof Uint8Array) || value.bytes.byteLength === 0 || value.bytes.byteLength > maximumCachedFeedBytes) {
        health.cacheReadOutcome = "invalid"; return null;
      }
      const feed = this.decodeFreshRailFeed(value.bytes);
      if (feed === null) { health.cacheReadOutcome = "invalid"; return null; }
      health.cacheOrigin = "persistent"; health.fetchedAt = value.fetchedAt; health.cacheReadOutcome = "accepted";
      return { feed, fetchedAt: value.fetchedAt };
    } catch { health.cacheReadOutcome = "error"; return null; }
  }

  private decodeFreshRailFeed(bytes: Uint8Array): transit_realtime.FeedMessage | null {
    const feed = gtfs.FeedMessage.decode(bytes), health = this.diagnostics;
    const generated = timestamp(feed.header.timestamp);
    health.headerAt = generated?.toISOString() ?? null; health.entityCount = feed.entity.length;
    // Persist only indexed rail updates, never the full regional bus feed.
    feed.entity = feed.entity.filter((entity) => this.tripIds.has(entity.tripUpdate?.trip.tripId ?? ""));
    health.railEntityCount = feed.entity.length;
    if (generated === null) { health.outcome = "missing-header"; return null; }
    if (this.now().getTime() - generated.getTime() > 5 * 60_000) { health.outcome = "stale-header"; return null; }
    if (generated.getTime() - this.now().getTime() > 120_000) { health.outcome = "future-header"; return null; }
    health.outcome = "ok";
    return feed;
  }
}
