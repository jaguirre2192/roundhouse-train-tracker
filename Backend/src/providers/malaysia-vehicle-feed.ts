import { transit_realtime } from "gtfs-realtime-bindings";

export const malaysiaVehicleFeedUrl = "https://api.data.gov.my/gtfs-realtime/vehicle-position/ktmb";
const minimumPollMilliseconds = 30_000;
const maximumCachedAgeMilliseconds = 4 * 60_000;
const maximumCachedBytes = 96 * 1_024;
const maximumResponseBytes = 2 * 1_024 * 1_024;

export interface MalaysiaCachedFeed { fetchedAt: number; bytes: Uint8Array }
export interface MalaysiaVehicleFeedOptions {
  /** Production reserves the shared-egress allowance persistently before network I/O. */
  reserveRequest?: () => Promise<boolean>;
  deferRequestUntil?: (until: number) => Promise<void>;
  readFeed?: () => Promise<MalaysiaCachedFeed | null>;
  writeFeed?: (value: MalaysiaCachedFeed) => Promise<void>;
}
interface FeedCache {
  loadedAt: number;
  expiresAt: number;
  value: Promise<transit_realtime.FeedMessage>;
}
interface PersistedFeed { fetchedAt: number; feed: transit_realtime.FeedMessage }
class CooldownPersistenceError extends Error {
  constructor() { super("Malaysia GTFS-RT cooldown persistence failed"); }
}

// Standalone callers share the official endpoint's cooldown in this isolate.
// The Watcher additionally supplies its singleton persistent reservation/store.
let sharedFeed: FeedCache | null = null;

async function boundedBody(response: Response): Promise<Uint8Array> {
  if (Number(response.headers.get("content-length")) > maximumResponseBytes) {
    await response.body?.cancel();
    throw new Error("Malaysia GTFS-RT exceeds byte limit");
  }
  if (response.body === null) throw new Error("Malaysia GTFS-RT has no body");
  const reader = response.body.getReader(), chunks: Uint8Array[] = [];
  let length = 0;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > maximumResponseBytes) {
      await reader.cancel();
      throw new Error("Malaysia GTFS-RT exceeds byte limit");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return bytes;
}

export class MalaysiaVehicleFeed {
  private cachedFeed: FeedCache | null = null;
  private readonly useShared: boolean;

  constructor(
    private readonly feedUrl: string,
    private readonly fetcher: typeof fetch,
    private readonly now: () => Date,
    private readonly options: MalaysiaVehicleFeedOptions,
  ) {
    this.useShared = feedUrl === malaysiaVehicleFeedUrl && options.reserveRequest === undefined
      && options.deferRequestUntil === undefined && options.readFeed === undefined && options.writeFeed === undefined;
  }

  feed(): Promise<transit_realtime.FeedMessage> {
    const now = this.now().getTime(), current = this.useShared ? sharedFeed : this.cachedFeed;
    if (current !== null) {
      if (now < current.loadedAt) {
        current.expiresAt = now + (current.expiresAt - current.loadedAt);
        current.loadedAt = now;
      }
      if (now < current.expiresAt) return current.value;
    }
    const entry: FeedCache = { loadedAt: now, expiresAt: now + minimumPollMilliseconds,
      value: Promise.resolve().then(() => this.load(entry)) };
    if (this.useShared) sharedFeed = entry;
    else this.cachedFeed = entry;
    return entry.value;
  }

  private async load(entry: FeedCache): Promise<transit_realtime.FeedMessage> {
    const persisted = await this.readPersisted();
    if (persisted !== null && this.now().getTime() - persisted.fetchedAt < minimumPollMilliseconds) {
      // A recreation must retain the original poll deadline, not renew its age.
      entry.expiresAt = persisted.fetchedAt + minimumPollMilliseconds;
      return persisted.feed;
    }
    // Fail closed if the owner cannot reserve its global allowance. Older
    // persisted feeds still undergo the overlay's own point-age/identity gates.
    if (this.options.reserveRequest !== undefined && !await this.options.reserveRequest()) {
      return persisted?.feed ?? transit_realtime.FeedMessage.create({ header: { gtfsRealtimeVersion: "2.0" } });
    }
    try {
      const response = await this.fetcher(this.feedUrl, {
        // The official endpoint returns 406 for explicit protobuf Accept values.
        headers: { "user-agent": "TrainTracker/0.3 (+https://github.com/jaguirre2192)" },
        signal: AbortSignal.timeout(12_000),
      });
      if (!response.ok) {
        const retryAfter = response.headers.get("retry-after");
        const retryAt = retryAfter === null ? Number.NaN : /^\d+$/u.test(retryAfter.trim())
          ? this.now().getTime() + Number(retryAfter) * 1_000 : Date.parse(retryAfter);
        await response.body?.cancel();
        if (Number.isFinite(retryAt) && retryAt > entry.expiresAt && retryAt > this.now().getTime()) {
          entry.expiresAt = retryAt;
          if (this.options.deferRequestUntil !== undefined) {
            try { await this.options.deferRequestUntil(retryAt); }
            catch { throw new CooldownPersistenceError(); }
          }
        }
        throw new Error(`Malaysia GTFS-RT returned ${response.status}`);
      }
      const bytes = await boundedBody(response), feed = transit_realtime.FeedMessage.decode(bytes);
      if (this.options.writeFeed !== undefined && bytes.byteLength <= maximumCachedBytes) {
        // Persist empty feeds too: a previous vehicle must not reappear on reset.
        try { await this.options.writeFeed({ fetchedAt: this.now().getTime(), bytes: new Uint8Array(bytes) }); }
        catch { /* Successful live data is usable even if its optional cache write fails. */ }
      }
      return feed;
    } catch (error) {
      if (persisted !== null && !(error instanceof CooldownPersistenceError)) return persisted.feed;
      throw error;
    }
  }

  private async readPersisted(): Promise<PersistedFeed | null> {
    if (this.options.readFeed === undefined) return null;
    // A storage failure must not become an uncoordinated network fallback.
    const value = await this.options.readFeed();
    if (value === null) return null;
    const age = this.now().getTime() - value.fetchedAt;
    if (!Number.isFinite(value.fetchedAt) || value.fetchedAt <= 0 || age < 0
      || age > maximumCachedAgeMilliseconds || !(value.bytes instanceof Uint8Array)
      || value.bytes.byteLength === 0 || value.bytes.byteLength > maximumCachedBytes) return null;
    try { return { fetchedAt: value.fetchedAt, feed: transit_realtime.FeedMessage.decode(value.bytes) }; }
    catch { return null; }
  }
}
