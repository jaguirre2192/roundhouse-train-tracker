import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import { compileTrafiklabRegionalStatic } from "../src/providers/trafiklab-regional-static-compiler.js";
import { regionalCSV } from "../src/providers/trafiklab-regional-static-csv.js";
import { fixtureStream, regionalStaticFixture, regionalStaticTables } from "../worker-tests/fixtures/trafiklab-regional-static.js";

describe("streaming Skåne static compiler", () => {
  it("handles routes last, hashes all archive bytes and preserves unused sibling platforms", async () => {
    const bytes = regionalStaticFixture(), index = await compileTrafiklabRegionalStatic(fixtureStream(bytes, 1));
    expect(index.sourceHashes.regional).toBe(createHash("sha256").update(bytes).digest("hex"));
    expect(index.trips).toEqual([["1001", "1231", 0, [[1, 1, 85800, 85800], [4, 2, 87600, 87600]]]]);
    expect(index.services).toEqual([["20261113"]]);
    expect(index.stations).toEqual([
      ["20", "20", "Malmö, C", 55.6, 13, ""], ["21", "20", "Malmö, C", 55.6, 13, "1"],
      ["22", "20", "Malmö, C", 55.6, 13, "2"], ["30", "30", "Lund", 55.7, 13.2, ""], ["31", "30", "Lund", 55.7, 13.2, "3"],
    ]);
  });

  it("applies calendar exceptions over weekly service and bounds its date window", async () => {
    const tables = regionalStaticTables();
    tables["calendar.txt"] = tables["calendar.txt"]!.replace("5,0,0,0,0,0,0,0", "5,1,1,1,1,1,1,1");
    const index = await compileTrafiklabRegionalStatic(fixtureStream(regionalStaticFixture(tables)));
    expect(index.services[0]).toContain("20261112"); expect(index.services[0]).not.toContain("20261114");
    expect(index.services[0]?.at(-1)).toBe("20261130");
  });

  it("rejects archive, compressed-retention and actual inflated byte overruns", async () => {
    const bytes = regionalStaticFixture();
    for (const options of [{ maxCompressedBytes: 100 }, { maxSelectedCompressedBytes: 100 }, { maxInflatedBytes: 100 }]) {
      await expect(compileTrafiklabRegionalStatic(fixtureStream(bytes), options)).rejects.toThrow("Oversized");
    }
  });

  it("fails closed on missing tables, ambiguous identity, malformed calls and oversized rows", async () => {
    for (const mutation of [
      (t: Record<string, string>) => { delete t["routes.txt"]; },
      (t: Record<string, string>) => { t["trips.txt"] += "1,5,1001,1231\n"; },
      (t: Record<string, string>) => { t["stop_times.txt"] = t["stop_times.txt"]!.replace("24:20:00", "24:90:00"); },
      (t: Record<string, string>) => { t["stop_times.txt"] = t["stop_times.txt"]!.replace("31,2", "31,1"); },
      (t: Record<string, string>) => { t["stops.txt"] += "x".repeat(17_000); },
      (t: Record<string, string>) => { t["stops.txt"] = t["stops.txt"]!.replace("Lund", "x".repeat(161)); },
    ]) {
      const tables = regionalStaticTables(); mutation(tables);
      await expect(compileTrafiklabRegionalStatic(fixtureStream(regionalStaticFixture(tables)))).rejects.toThrow();
    }
  });

  it("cancels a stalled input when the outer deadline aborts", async () => {
    const controller = new AbortController(); let canceled = false;
    const stream = new ReadableStream<Uint8Array>({ cancel() { canceled = true; } });
    const result = compileTrafiklabRegionalStatic(stream, { signal: controller.signal });
    controller.abort(new Error("outer deadline"));
    await expect(result).rejects.toThrow("outer deadline"); expect(canceled).toBe(true);
  });

  it("parses quoted multiline/escaped fields split across UTF-8 bytes and enforces row caps", () => {
    const rows: Readonly<Record<string, string>>[] = [];
    const consume = regionalCSV(["id", "name"], 1, (row) => rows.push(row));
    const bytes = new TextEncoder().encode('id,name\r\n1,"Malmö\n""Central"""\r\n');
    for (const byte of bytes) consume(Uint8Array.of(byte), false); consume(new Uint8Array(), true);
    expect(rows).toEqual([{ id: "1", name: 'Malmö\n"Central"' }]);
    const bounded = regionalCSV(["id"], 1, () => undefined);
    expect(() => bounded(new TextEncoder().encode("id\n1\n2\n"), true)).toThrow("Excessive");
  });
});
