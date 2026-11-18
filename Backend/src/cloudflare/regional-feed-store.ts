interface FeedTransaction {
  get<T>(key: string): Promise<T | undefined>;
  put(key: string, value: unknown): Promise<void>;
}
interface FeedStorage {
  get<T>(key: string): Promise<T | undefined>;
  transaction<T>(work: (transaction: FeedTransaction) => Promise<T>): Promise<T>;
}
interface CachedFeed { fetchedAt: number; bytes: Uint8Array }

const maximumBytes = 96 * 1_024;
const maximumAgeMs = 4 * 60_000;

function valid(value: unknown, now: number): value is CachedFeed {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
  const feed = value as Partial<CachedFeed>;
  return Number.isFinite(now) && now >= 0 && typeof feed.fetchedAt === "number"
    && Number.isFinite(feed.fetchedAt) && feed.fetchedAt >= 0 && feed.fetchedAt <= now
    && now - feed.fetchedAt <= maximumAgeMs && feed.bytes instanceof Uint8Array
    && feed.bytes.byteLength > 0 && feed.bytes.byteLength <= maximumBytes;
}

/** The provider supplies validated rail-only protobuf; the store preserves its
 * original fetch age across Watcher instances without renewing the allowance. */
export class RegionalFeedStore {
  constructor(
    private readonly storage: FeedStorage,
    private readonly key = "regional-feed:trafiklab-skane",
    private readonly now: () => number = Date.now,
  ) {}

  async load(): Promise<CachedFeed | null> {
    const value = await this.storage.get<unknown>(this.key);
    return valid(value, this.now()) ? { fetchedAt: value.fetchedAt, bytes: new Uint8Array(value.bytes) } : null;
  }

  async save(value: CachedFeed): Promise<void> {
    if (!valid(value, this.now())) return;
    // Copy views into a bounded buffer; serializing a subarray can otherwise
    // retain the entire (potentially much larger) original protobuf buffer.
    const next = { fetchedAt: value.fetchedAt, bytes: new Uint8Array(value.bytes) };
    await this.storage.transaction(async (transaction) => {
      const previous = await transaction.get<unknown>(this.key);
      const now = this.now();
      if (!valid(next, now) || (valid(previous, now) && previous.fetchedAt >= next.fetchedAt)) return;
      await transaction.put(this.key, next);
    });
  }
}
