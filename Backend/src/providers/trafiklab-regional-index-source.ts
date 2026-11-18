import type { RegionalRailIndex } from "./trafiklab-regional-index.js";
import { isRegionalRailIndexFresh, parseRegionalRailIndex } from "./trafiklab-regional-index-schema.js";

const refreshMilliseconds = 60 * 60_000;
export interface RegionalIndexSourceOptions {
  bundledIndex: RegionalRailIndex;
  // Authenticated upload/storage is owned by the backend. This loader never
  // fetches private repository data, downloads ZIPs, or requires a static key.
  loadIndex: () => Promise<unknown>;
  now?: () => Date;
}

/** Shared hourly storage read; a failed update never extends prior expiry. */
export class TrafiklabRegionalIndexSource {
  private current: RegionalRailIndex | null;
  private nextRefresh = 0;
  private inflight: Promise<void> | null = null;
  private readonly now: () => Date;
  private origin: "bundled" | "stored" | "none" = "none";
  private lastReadAt: string | null = null;
  private lastReadOutcome: "not-read" | "reading" | "invalid-or-absent" | "accepted" | "unchanged-or-older" | "timeout" | "error" = "not-read";

  constructor(private readonly options: RegionalIndexSourceOptions) {
    this.now = options.now ?? (() => new Date());
    this.current = parseRegionalRailIndex(options.bundledIndex, this.now());
    if (this.current !== null) this.origin = "bundled";
  }

  health() {
    return { origin: this.origin, fresh: this.current !== null && isRegionalRailIndexFresh(this.current, this.now()),
      feedVersion: this.current?.feedVersion ?? null, expiresAt: this.current?.expiresAt ?? null,
      trips: this.current?.trips.length ?? 0, lastReadAt: this.lastReadAt, lastReadOutcome: this.lastReadOutcome };
  }

  async get(): Promise<RegionalRailIndex | null> {
    const now = this.now();
    if (this.inflight !== null) await this.inflight;
    else if (now.getTime() >= this.nextRefresh) {
      this.nextRefresh = now.getTime() + refreshMilliseconds;
      const pending = this.refresh(); this.inflight = pending;
      try { await pending; } finally { this.inflight = null; }
    }
    return this.current !== null && isRegionalRailIndexFresh(this.current, this.now()) ? this.current : null;
  }

  private async refresh(): Promise<void> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    this.lastReadAt = this.now().toISOString(); this.lastReadOutcome = "reading";
    let timedOut = false;
    try {
      const loaded = await Promise.race([
        this.options.loadIndex(),
        new Promise<null>((resolve) => { timer = setTimeout(() => { timedOut = true; resolve(null); }, 1_500); }),
      ]);
      const value = parseRegionalRailIndex(loaded, this.now());
      if (value === null) { this.lastReadOutcome = timedOut ? "timeout" : "invalid-or-absent"; return; }
      if (this.current === null || value.generatedAt > this.current.generatedAt
        || (value.generatedAt === this.current.generatedAt && value.sourceHashes.regional !== this.current.sourceHashes.regional)) {
        this.current = value; this.origin = "stored"; this.lastReadOutcome = "accepted";
      } else this.lastReadOutcome = "unchanged-or-older";
    } catch {
      this.lastReadOutcome = "error";
      // Keep validated prior data only while fresh. Rejected updates never
      // enter the cache and cannot prolong the fallback's source deadline.
    } finally { if (timer !== undefined) clearTimeout(timer); }
  }
}
