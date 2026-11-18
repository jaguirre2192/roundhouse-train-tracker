import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { DenmarkSiriStore, type DenmarkSiriStorage } from "../src/cloudflare/denmark-siri-store.js";
import { siriAt, siriCall, siriClock, siriDelivery, siriJourney } from "../tests/helpers/denmark-siri-store-fixtures.js";

const snapshot = { serviceDate: "2026-11-16", product: "IC 2360" };

describe("Denmark SIRI in actual Durable Object storage", () => {
  it("retains original clocks across store instances and serializes concurrent partial updates", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const prefix = `test-denmark-siri:${crypto.randomUUID()}`;
      await new DenmarkSiriStore(state.storage, prefix).ingest(siriDelivery(), siriClock);
      await Promise.all([10_000, 30_000, 20_000].map((offset) => new DenmarkSiriStore(state.storage, prefix).ingest(
        siriDelivery([siriJourney({ observedAt: siriAt(offset), calls: [siriCall("8601309", siriAt(600_000), siriAt(660_000 + offset))] })], siriAt(offset)),
        siriAt(31_000),
      )));
      const store = new DenmarkSiriStore(state.storage, prefix);
      const partial = siriDelivery([siriJourney({ observedAt: siriAt(40_000), calls: [siriCall("8601770")] })], siriAt(40_000));
      await store.ingest(partial, siriAt(41_000));
      const [journey] = await new DenmarkSiriStore(state.storage, prefix).load(snapshot, siriAt(42_000));
      expect(journey?.calls).toEqual([
        expect.objectContaining({ stopPointRef: "8601309", expectedDeparture: siriAt(690_000), observedAt: siriAt(30_000) }),
        expect.objectContaining({ stopPointRef: "8601770", observedAt: siriAt(40_000) }),
      ]);
      expect(journey?.receivedAt).toBe(siriAt(41_000));
      expect(await store.ingest(partial, siriAt(80_000))).toMatchObject({ outcome: "unchanged" });
      expect((await store.load(snapshot, siriAt(81_000)))[0]?.receivedAt).toBe(siriAt(41_000));
      expect(await store.ingest(siriDelivery(), siriAt(400_000))).toMatchObject({ outcome: "ignored-stale", journeys: 0 });
      expect([...await state.storage.list({ prefix })].map(([key]) => key)).toEqual([`${prefix}:manifest`]);
    });
  });

  it("commits bounded chunks, ignores expired data on reads and removes it at the next ingest", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const prefix = `test-denmark-siri:${crypto.randomUUID()}`;
      const store = new DenmarkSiriStore(state.storage, prefix);
      const calls = Array.from({ length: 900 }, (_, index) => siriCall(`86${String(index).padStart(5, "0")}`));
      await store.ingest(siriDelivery([siriJourney({ calls })]), siriClock);
      const entries = await state.storage.list<string>({ prefix });
      expect(entries.size).toBeGreaterThan(2);
      for (const value of entries.values()) expect(new TextEncoder().encode(value).byteLength).toBeLessThan(128 * 1024);
      expect((await new DenmarkSiriStore(state.storage, prefix).load(snapshot, siriAt(299_999)))[0]?.calls).toHaveLength(900);
      expect(await store.health(siriAt(300_001))).toMatchObject({ ready: false, journeys: 0, calls: 0 });
      expect((await state.storage.list({ prefix })).size).toBe(entries.size);
      await store.ingest(siriDelivery(), siriAt(300_002));
      expect((await state.storage.list({ prefix })).size).toBe(1);
    });
  });

  it("rejects ingestion when the durable transaction aborts and preserves the previous committed forecast", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const prefix = `test-denmark-siri:${crypto.randomUUID()}`;
      const store = new DenmarkSiriStore(state.storage, prefix);
      await store.ingest(siriDelivery(), siriClock);
      const before = await store.load(snapshot, siriAt(1_000));
      const failing: DenmarkSiriStorage = {
        transaction: (work) => state.storage.transaction(async (transaction) => {
          await work(transaction);
          throw new Error("forced durable rollback");
        }),
      };
      await expect(new DenmarkSiriStore(failing, prefix).ingest(siriDelivery([
        siriJourney({ observedAt: siriAt(30_000), calls: [siriCall("8601770")] }),
      ], siriAt(30_000)), siriAt(31_000))).rejects.toThrow("forced durable rollback");
      expect(await new DenmarkSiriStore(state.storage, prefix).load(snapshot, siriAt(32_000))).toEqual(before);
    });
  });

  it("keeps diagnostics durable, operator-specific and bounded to twelve public timetable anchors", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const prefix = `test-denmark-siri:${crypto.randomUUID()}`;
      const calls = [siriCall("8601309"), siriCall("8601770"), siriCall("8600223")];
      const messages = ["DSB", "DSB Vores Tog"].flatMap((operator, operatorIndex) =>
        Array.from({ length: 5 }, (_, index) => siriJourney({ reference: `${operator}-${index}`,
          trainNumber: String(2360 + operatorIndex * 1000 + index), observedAt: siriAt(operatorIndex * 5_000 + index * 1_000), calls })
          .replace("<OperatorRef>DSB</OperatorRef>", `<OperatorRef>${operator}</OperatorRef>`)));
      await new DenmarkSiriStore(state.storage, prefix).ingest(siriDelivery(messages, siriAt(9_000)), siriAt(10_000));
      const health = await new DenmarkSiriStore(state.storage, prefix).health(siriAt(11_000));
      expect(health.operators?.DSB).toMatchObject({ journeys: 5, calls: 15, latestObservedAt: siriAt(4_000) });
      expect(health.operators?.["DSB Vores Tog"]).toMatchObject({ journeys: 5, calls: 15, latestObservedAt: siriAt(9_000) });
      const samples = Object.values(health.operators!).flatMap((operator) => operator.samples);
      expect(samples).toHaveLength(6);
      expect(samples.reduce((sum, sample) => sum + sample.anchors.length, 0)).toBe(12);
      expect(samples.every((sample) => sample.anchors.length === 2 && sample.callCount === 3
        && !JSON.stringify(sample).includes("expectedDeparture"))).toBe(true);
      const afterExpiry = await new DenmarkSiriStore(state.storage, prefix).health(siriAt(310_000));
      expect(afterExpiry.operators?.DSB).toEqual({ journeys: 0, calls: 0, latestObservedAt: null, samples: [] });
      expect(afterExpiry.operators?.["DSB Vores Tog"]).toEqual({ journeys: 0, calls: 0, latestObservedAt: null, samples: [] });
    });
  });
});
