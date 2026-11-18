import { describe, expect, it } from "vitest";
import { DenmarkSiriIngestError, DenmarkSiriStore } from "../src/cloudflare/denmark-siri-store.js";
import { denmarkSiriBatchLimits } from "../src/cloudflare/denmark-siri-batch.js";
import { MemorySiriStorage, siriAt, siriCall, siriClock, siriDelivery, siriJourney } from "./helpers/denmark-siri-store-fixtures.js";

const snapshot = { serviceDate: "2026-11-16", product: "IC 2360" };

describe("atomic Denmark delivery batches and write budget", () => {
  it("persists fourteen different journeys with fourteen chunks and only one manifest write", async () => {
    const storage = new MemorySiriStorage();
    const deliveries = Array.from({ length: 14 }, (_, index) => siriDelivery([
      siriJourney({ reference: `run-${index}`, trainNumber: String(2360 + index) }),
    ]));
    expect(await new DenmarkSiriStore(storage).ingestBatch(deliveries, siriClock))
      .toMatchObject({ outcome: "stored", deliveries: 14, ignoredStale: 0, journeys: 14, calls: 14 });
    expect(storage.putCount).toBe(15);
    expect((await new DenmarkSiriStore(storage).health(siriClock)).journeys).toBe(14);
    expect(storage.putCount).toBe(15);
  });

  it("coalesces fourteen partial updates to one journey without losing any call or renewing a replay", async () => {
    const storage = new MemorySiriStorage();
    const deliveries = Array.from({ length: 14 }, (_, index) => siriDelivery([
      siriJourney({ observedAt: siriAt(index * 1_000), calls: [siriCall(`86${String(index).padStart(5, "0")}`)] }),
    ], siriAt(index * 1_000)));
    const store = new DenmarkSiriStore(storage);
    expect(await store.ingestBatch(deliveries, siriAt(14_000))).toMatchObject({ journeys: 1, calls: 14 });
    expect(storage.putCount).toBe(2);
    const [saved] = await store.load(snapshot, siriAt(15_000));
    expect(saved).toMatchObject({ observedAt: siriAt(13_000), receivedAt: siriAt(14_000) });
    expect(saved?.calls).toHaveLength(14);
    expect(await store.ingestBatch(deliveries, siriAt(70_000))).toMatchObject({ outcome: "unchanged", ignoredStale: 0 });
    expect(storage.putCount).toBe(2);
    expect(await new DenmarkSiriStore(storage).load(snapshot, siriAt(71_000))).toEqual([saved]);
  });

  it("matches sequential partial/conflict merging against the already saved train identity", async () => {
    const batch = new MemorySiriStorage(), sequential = new MemorySiriStorage();
    const updates = [
      siriJourney({ observedAt: siriAt(30_000), calls: [siriCall("8601770")] }),
      siriJourney({ trainNumber: "999", observedAt: siriAt(40_000), calls: [siriCall("8601309", siriAt(600_000), siriAt(900_000))] }),
      siriJourney({ observedAt: siriAt(41_000), calls: [siriCall("8601309", siriAt(600_000), siriAt(700_000))] }),
      siriJourney({ observedAt: siriAt(41_000), calls: [siriCall("8601309", siriAt(600_000), siriAt(800_000))] }),
    ].map(journey => siriDelivery([journey], siriAt(42_000)));
    for (const storage of [batch, sequential]) await new DenmarkSiriStore(storage).ingest(siriDelivery(), siriClock);
    for (const xml of updates) await new DenmarkSiriStore(sequential).ingest(xml, siriAt(43_000));
    await new DenmarkSiriStore(batch).ingestBatch(updates, siriAt(43_000));
    const [saved] = await new DenmarkSiriStore(batch).load(snapshot, siriAt(44_000));
    expect(saved?.calls[0]).toMatchObject({ conflicted: true, observedAt: siriAt(41_000) });
    expect(saved?.calls).toHaveLength(2);
    expect(await new DenmarkSiriStore(batch).load(snapshot, siriAt(44_000)))
      .toEqual(await new DenmarkSiriStore(sequential).load(snapshot, siriAt(44_000)));
  });

  it("counts stale deliveries separately while retaining the fresh member's source clock", async () => {
    const storage = new MemorySiriStorage();
    const store = new DenmarkSiriStore(storage);
    const fresh = siriDelivery([siriJourney({ observedAt: siriAt(310_000) })], siriAt(310_000));
    expect(await store.ingestBatch([siriDelivery(), fresh], siriAt(311_000)))
      .toMatchObject({ outcome: "stored", deliveries: 2, ignoredStale: 1, journeys: 1 });
    expect((await store.load(snapshot, siriAt(312_000)))[0]?.observedAt).toBe(siriAt(310_000));
    expect(await store.ingestBatch([siriDelivery()], siriAt(313_000)))
      .toMatchObject({ outcome: "ignored-stale", deliveries: 1, ignoredStale: 1, journeys: 1 });
  });

  it("validates every delivery before persisting any member", async () => {
    const storage = new MemorySiriStorage(), store = new DenmarkSiriStore(storage);
    await store.ingest(siriDelivery(), siriClock);
    const before = structuredClone(storage.values), writes = storage.putCount;
    const next = siriDelivery([siriJourney({ observedAt: siriAt(30_000) })], siriAt(30_000));
    for (const bad of ["<Siri>", siriDelivery([siriJourney({ observedAt: siriAt(300_000) })], siriAt(300_000))]) {
      await expect(store.ingestBatch([next, bad], siriAt(31_000))).rejects.toBeInstanceOf(DenmarkSiriIngestError);
      expect(storage.values).toEqual(before); expect(storage.putCount).toBe(writes);
    }
  });

  it("bounds batch count and aggregate UTF8 bytes independently of member character length", async () => {
    const storage = new MemorySiriStorage(), store = new DenmarkSiriStore(storage);
    for (const deliveries of [[], Array.from({ length: 15 }, () => siriDelivery()),
      ["😀".repeat(denmarkSiriBatchLimits.xmlBytes / 4 + 1)]]) {
      await expect(store.ingestBatch(deliveries, siriClock)).rejects.toBeInstanceOf(DenmarkSiriIngestError);
    }
    expect(storage.putCount).toBe(0);
  });

  it("keeps expiration and corrupt-record reads useful when durable writes fail", async () => {
    const storage = new MemorySiriStorage(), store = new DenmarkSiriStore(storage);
    await store.ingest(siriDelivery(), siriClock);
    const before = structuredClone(storage.values), writes = storage.putCount;
    storage.failWrites = true;
    expect(await store.load(snapshot, siriAt(301_000))).toEqual([]);
    expect(await store.health(siriAt(301_000))).toMatchObject({ ready: false, journeys: 0 });
    expect(storage.values).toEqual(before); expect(storage.putCount).toBe(writes); expect(storage.deleteCount).toBe(0);
  });
});
