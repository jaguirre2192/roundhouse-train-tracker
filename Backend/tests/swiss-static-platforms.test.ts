import { describe, expect, it } from "vitest";
import { strToU8, zipSync } from "fflate";
import { compileSwissPlatforms, SwissStaticPlatforms } from "../src/providers/swiss-static-platforms.js";
import { swissStaticTables } from "../src/providers/swiss-static-zip.js";

const version = "20261111";
const now = () => new Date("2026-11-13T21:04:52Z");
const url = `https://data.opentransportdata.swiss/dataset/00000000-0000/resource/11111111-1111/download/gtfs_fp2026_${version}.zip`;
const info = `feed_version,feed_start_date,feed_end_date\n${version},20251214,20261212\n`;
// Exact examples captured from the official 20261111 stops.txt on 2026-11-13.
const stops = "stop_id,platform_code,location_type\n"
  + "ch:1:sloid:212_gen:missingSLOID_pf:45.5,45/5,\n"
  + "ch:1:sloid:6286_gen:ch:1:sloid:6286:2:3_pf:3.4,3/4,\n"
  + "8029103_gen:missingSLOID_pf:3.S.d,3 Süd,\n"
  + "ch:1:sloid:7000:0:349752,2A-D,\n";

function source(stopTable = stops, feedInfo = info) {
  const archive = zipSync({ "feed_info.txt": strToU8(feedInfo), "stops.txt": strToU8(stopTable), "stop_times.txt": strToU8("unused") });
  const requests: { url: string; range: string | null }[] = [];
  const fetcher: typeof fetch = async (input, init) => {
    const range = new Headers(init?.headers).get("range"); requests.push({ url: String(input), range });
    if (!range) return new Response(`<a href="${url}">Download</a>`);
    const match = range.match(/^bytes=(\d*)-(\d+)$/u)!;
    const start = match[1] ? Number(match[1]) : Math.max(0, archive.length - Number(match[2]));
    const end = match[1] ? Math.min(Number(match[2]), archive.length - 1) : archive.length - 1;
    return new Response(archive.slice(start, end + 1), { status: 206, headers: { "content-range": `bytes ${start}-${end}/${archive.length}` } });
  };
  return { archive, fetcher, requests };
}

describe("version-matched Swiss static platforms", () => {
  it("preserves slash, space and accented labels using exact stop IDs and caches one version", async () => {
    const fixture = source(), lookup = new SwissStaticPlatforms(fixture.fetcher, now);
    const index = await lookup.load(version, "2026-11-13");
    expect([...index!.platforms.values()]).toEqual(["45/5", "3/4", "3 Süd", "2A-D"]);
    expect(index!.platforms.get("ch:1:sloid:7000:0:34975")).toBeUndefined();
    expect(await lookup.load(version, "2026-11-13")).toBe(index);
    expect(fixture.requests).toHaveLength(4); // Catalog, directory and two bounded tables.
    expect(fixture.requests.slice(1).every((request) => request.range !== null)).toBe(true);
  });

  it.each(["20261028", "20261114", "20260230", "", "2026-11-11"])("rejects stale, future or malformed feed version %s without downloading", async (feedVersion) => {
    const fixture = source();
    expect(await new SwissStaticPlatforms(fixture.fetcher, now).load(feedVersion, "2026-11-13")).toBeNull();
    expect(fixture.requests).toHaveLength(0);
  });

  it.each(["20261113", "2026--11-13", "2026-02-30"])("rejects malformed service date %s", async (serviceDate) => {
    const fixture = source();
    expect(await new SwissStaticPlatforms(fixture.fetcher, now).load(version, serviceDate)).toBeNull();
    expect(fixture.requests).toHaveLength(0);
  });

  it("rejects a service date outside the exact static validity window", async () => {
    const fixture = source(stops, `feed_version,feed_start_date,feed_end_date\n${version},20261101,20261112\n`);
    expect(await new SwissStaticPlatforms(fixture.fetcher, now).load(version, "2026-11-13")).toBeNull();
  });

  it.each([
    [stops, info.replace(version, "20261107")],
    [stops + "ch:1:sloid:7000:0:349752,9,\n", info],
    ["stop_id,platform_code,location_type\n\"unfinished,3,\n", info],
    ["stop_id,location_type\nch:1:sloid:212,\n", info],
  ])("withholds corrupt, mismatched or ambiguous dictionaries", async (table, metadata) => {
    const fixture = source(table, metadata), lookup = new SwissStaticPlatforms(fixture.fetcher, now);
    expect(await lookup.load(version, "2026-11-13")).toBeNull();
    const count = fixture.requests.length;
    expect(await lookup.load(version, "2026-11-13")).toBeNull();
    expect(fixture.requests).toHaveLength(count); // Failure backoff.
  });

  it("expires a cached mapping rather than using it after the freshness limit", async () => {
    let time = now(); const fixture = source(), lookup = new SwissStaticPlatforms(fixture.fetcher, () => time);
    expect(await lookup.load(version, "2026-11-13")).not.toBeNull();
    time = new Date("2026-11-20T00:00:00Z");
    expect(await lookup.load(version, "2026-11-20")).toBeNull();
    expect(fixture.requests).toHaveLength(4);
  });

  it("rejects malformed CSV directly and retains printable literal punctuation", () => {
    const tables = new Map([["feed_info.txt", strToU8(info)], ["stops.txt", strToU8(stops)]]);
    expect(compileSwissPlatforms(tables, version).platforms.get("8029103_gen:missingSLOID_pf:3.S.d")).toBe("3 Süd");
    tables.set("stops.txt", strToU8('stop_id,platform_code,location_type\n"stop"garbage,1,\n'));
    expect(() => compileSwissPlatforms(tables, version)).toThrow("quoting");
  });

  it("refuses a server that ignores Range before reading a national archive", async () => {
    let cancelled = false;
    const fetcher: typeof fetch = async () => new Response(new ReadableStream({ cancel() { cancelled = true; } }));
    await expect(swissStaticTables(url, fetcher, AbortSignal.timeout(1_000))).rejects.toThrow("byte ranges");
    expect(cancelled).toBe(true);
  });

  it("rejects oversized selected tables before fetching their bytes", async () => {
    const fixture = source(), view = new DataView(fixture.archive.buffer);
    for (let offset = 0; offset < fixture.archive.length - 46; offset += 1) {
      if (view.getUint32(offset, true) === 0x02014b50) { view.setUint32(offset + 24, 21 * 1024 * 1024, true); break; }
    }
    await expect(swissStaticTables(url, fixture.fetcher, AbortSignal.timeout(1_000))).rejects.toThrow("Unsupported Swiss static table");
    expect(fixture.requests).toHaveLength(1);
  });

  it("rejects a corrupt table checksum", async () => {
    const fixture = source();
    const view = new DataView(fixture.archive.buffer);
    for (let offset = 0; offset < fixture.archive.length - 46; offset += 1) {
      if (view.getUint32(offset, true) === 0x02014b50) {
        view.setUint32(offset + 16, view.getUint32(offset + 16, true) ^ 1, true); break;
      }
    }
    await expect(swissStaticTables(url, fixture.fetcher, AbortSignal.timeout(1_000))).rejects.toThrow("Corrupt Swiss static table");
  });
});
