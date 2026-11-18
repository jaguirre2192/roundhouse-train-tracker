// A per-instance provider cache with a TTL per entry and a hard size cap. Overlay
// caches are keyed by trip id or station, so a long-lived Node process (or a warm
// Worker isolate) would otherwise grow without bound.
export class ExpiringCache<V> {
  private readonly entries = new Map<string, { expiresAt: number; value: V }>();

  constructor(private readonly maximumEntries: number) {}

  get size(): number {
    return this.entries.size;
  }

  get(key: string, now: number): V | undefined {
    const entry = this.entries.get(key);
    if (entry === undefined) return undefined;
    if (entry.expiresAt <= now) {
      this.entries.delete(key);
      return undefined;
    }
    return entry.value;
  }

  set(key: string, value: V, now: number, ttlMilliseconds: number): void {
    this.entries.delete(key);
    this.entries.set(key, { expiresAt: now + ttlMilliseconds, value });
    if (this.entries.size <= this.maximumEntries) return;
    for (const [candidate, entry] of this.entries) {
      if (entry.expiresAt <= now) this.entries.delete(candidate);
    }
    // Map iteration is insertion order, so the first keys are the least recently stored.
    for (const candidate of this.entries.keys()) {
      if (this.entries.size <= this.maximumEntries) break;
      this.entries.delete(candidate);
    }
  }

  delete(key: string, value?: V): void {
    if (value === undefined || this.entries.get(key)?.value === value) this.entries.delete(key);
  }
}

// Shares one in-flight or recent load per key. A rejected load is evicted as soon
// as it settles, so a transient provider failure is retried on the next request
// instead of being replayed for the whole TTL.
export function cachedLoad<V>(
  cache: ExpiringCache<Promise<V>>,
  key: string,
  now: number,
  ttlMilliseconds: number,
  load: () => Promise<V>,
): Promise<V> {
  const cached = cache.get(key, now);
  if (cached !== undefined) return cached;
  const value = load();
  cache.set(key, value, now, ttlMilliseconds);
  value.catch(() => cache.delete(key, value));
  return value;
}
