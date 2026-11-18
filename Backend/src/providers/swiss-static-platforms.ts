import { swissCSV } from "./swiss-static-csv.js";
import { swissBytes, swissStaticTables } from "./swiss-static-zip.js";

export interface SwissPlatformIndex {
  feedVersion: string;
  startDate: string;
  endDate: string;
  platforms: ReadonlyMap<string, string>;
}
export interface SwissPlatformLookup {
  load(feedVersion: string, serviceDate: string): Promise<SwissPlatformIndex | null>;
}
const day = 86_400_000;

function date(value: string): number {
  if (!/^\d{8}$/u.test(value)) return NaN;
  const iso = `${value.slice(0, 4)}-${value.slice(4, 6)}-${value.slice(6, 8)}`;
  const time = Date.parse(`${iso}T00:00:00Z`);
  return Number.isFinite(time) && new Date(time).toISOString().slice(0, 10) === iso ? time : NaN;
}

function current(version: string, now: Date): boolean {
  const age = now.getTime() - date(version);
  return Number.isFinite(age) && age >= 0 && age <= 8 * day;
}

export function compileSwissPlatforms(tables: ReadonlyMap<string, Uint8Array>, version: string): SwissPlatformIndex {
  const info = tables.get("feed_info.txt"), stops = tables.get("stops.txt");
  if (!info || !stops) throw new Error("Incomplete Swiss platform tables");
  let index: SwissPlatformIndex | null = null;
  const platforms = new Map<string, string>(), seen = new Set<string>();
  swissCSV(info, ["feed_version", "feed_start_date", "feed_end_date"], (row) => {
    if (index || row.feed_version !== version || !Number.isFinite(date(version))
      || !Number.isFinite(date(row.feed_start_date!)) || !Number.isFinite(date(row.feed_end_date!))
      || row.feed_start_date! > row.feed_end_date!) throw new Error("Wrong Swiss static feed metadata");
    index = { feedVersion: version, startDate: row.feed_start_date!, endDate: row.feed_end_date!, platforms };
  });
  swissCSV(stops, ["stop_id", "platform_code", "location_type"], (row) => {
    const id = row.stop_id!, label = row.platform_code!;
    if (id.length === 0 || id.length > 240 || seen.has(id)) throw new Error("Duplicate or invalid Swiss static stop");
    seen.add(id);
    if (!["", "0"].includes(row.location_type!) || label.length === 0 || label.length > 40 || label !== label.trim()
      || /\p{C}/u.test(label) || !/[\p{Letter}\p{Number}]/u.test(label)) return;
    if (platforms.size >= 30_000) throw new Error("Excessive Swiss platform labels");
    platforms.set(id, label);
  });
  if (!index || platforms.size === 0) throw new Error("Empty Swiss platform dictionary");
  return index;
}

/** Exact-version, lazy, bounded lookup. A failed refresh never removes realtime delay/cancellation data. */
export class SwissStaticPlatforms implements SwissPlatformLookup {
  private cache: { key: string; retryAt: number; value: Promise<SwissPlatformIndex | null> } | null = null;
  constructor(private readonly fetcher: typeof fetch = fetch, private readonly now: () => Date = () => new Date()) {}

  async load(feedVersion: string, serviceDate: string): Promise<SwissPlatformIndex | null> {
    if (!current(feedVersion, this.now()) || !/^\d{4}-\d{2}-\d{2}$/u.test(serviceDate)) return null;
    const service = serviceDate.replaceAll("-", "");
    if (!Number.isFinite(date(service))) return null;
    const year = Number(service.slice(0, 4));
    const december = new Date(Date.UTC(year, 11, 8));
    const change = Date.UTC(year, 11, 8 + (7 - december.getUTCDay()) % 7);
    const timetableYear = date(service) >= change ? year + 1 : year;
    const key = `${timetableYear}:${feedVersion}`, time = this.now().getTime();
    if (!this.cache || this.cache.key !== key || time >= this.cache.retryAt) {
      const value = this.download(timetableYear, feedVersion).catch(() => null);
      // Reuse a successful immutable version for its freshness window. Retry a
      // missing/corrupt source after 15 minutes, avoiding request storms.
      this.cache = { key, retryAt: time + 15 * 60_000, value };
      void value.then((index) => {
        if (index && this.cache?.key === key) this.cache.retryAt = date(feedVersion) + 8 * day;
      });
    }
    const index = await this.cache.value;
    return index && current(feedVersion, this.now()) && service >= index.startDate && service <= index.endDate ? index : null;
  }

  private async download(year: number, version: string): Promise<SwissPlatformIndex> {
    const signal = AbortSignal.timeout(12_000);
    const catalog = await this.fetcher(`https://data.opentransportdata.swiss/dataset/timetable-${year}-gtfs2020`, { signal });
    const html = new TextDecoder("utf-8", { fatal: true }).decode(await swissBytes(catalog, 1_048_576));
    const candidates = new Set((html.match(/https:\/\/data\.opentransportdata\.swiss\/dataset\/[a-f0-9-]+\/resource\/[a-f0-9-]+\/download\/gtfs_fp\d{4}_\d{8}\.zip/gu) ?? [])
      .filter((url) => url.endsWith(`/gtfs_fp${year}_${version}.zip`)));
    if (candidates.size !== 1) throw new Error("Missing or ambiguous Swiss static version");
    return compileSwissPlatforms(await swissStaticTables([...candidates][0]!, this.fetcher, signal), version);
  }
}
