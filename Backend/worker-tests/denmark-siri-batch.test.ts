import { createExecutionContext, env, runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/cloudflare/index.js";
import type { WorkerEnv } from "../src/cloudflare/env.js";
import type { TrainTrackerWatcher } from "../src/cloudflare/watcher-object.js";
import { DenmarkSiriStore, type DenmarkSiriStorage } from "../src/cloudflare/denmark-siri-store.js";
import { denmarkSiriBatchContentType, denmarkSiriBatchLimits } from "../src/cloudflare/denmark-siri-batch.js";
import { handleDenmarkSiriRefresh } from "../src/cloudflare/denmark-siri-refresh-route.js";
import { siriAt, siriCall, siriClock, siriDelivery, siriJourney } from "../tests/helpers/denmark-siri-store-fixtures.js";

const prefix = "denmark-siri:v1", secret = "batch-refresh-test-secret-more-than-32-characters";
const snapshot = { serviceDate: "2026-11-16", product: "IC 2360" };
type Input = Parameters<typeof worker.fetch>[0];
function request(deliveries: unknown, headers: HeadersInit = {}): Input {
  return new Request("https://watcher.test/internal/rail-data/denmark-siri", { method: "POST", body: JSON.stringify({ deliveries }),
    headers: { authorization: `Bearer ${secret}`, "content-type": denmarkSiriBatchContentType, ...Object.fromEntries(new Headers(headers)) } }) as Input;
}
function send(input: Input) {
  return worker.fetch(input, { ...env, RAIL_DATA_REFRESH_SECRET: secret } as WorkerEnv, createExecutionContext());
}
function countWrites(storage: DenmarkSiriStorage, cost: { puts: number; deletes: number }): DenmarkSiriStorage {
  return { transaction: work => storage.transaction(tx => work({
    get: <T>(key: string) => tx.get<T>(key),
    put: async (key, value) => { cost.puts++; await tx.put(key, value); },
    delete: async keys => { cost.deletes += keys.length; return tx.delete(keys); },
  })) };
}
beforeEach(async () => {
  vi.useFakeTimers({ toFake: ["Date"] }); vi.setSystemTime(new Date(siriClock));
  await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
    const keys = [...(await state.storage.list({ prefix })).keys()];
    if (keys.length) await state.storage.delete(keys);
  });
});
afterEach(() => { vi.restoreAllMocks(); vi.useRealTimers(); });

describe("authenticated atomic Denmark SIRI batch publication", () => {
  it("commits every partial forecast before issuing a count-matched durable ACK", async () => {
    const deliveries = [siriDelivery(), siriDelivery([siriJourney({ calls: [siriCall("8601770")] })])];
    const response = await send(request(deliveries));
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ accepted: true, source: "denmark-siri", outcome: "stored", deliveries: 2, ignoredStale: 0, journeys: 1, calls: 2 });
    expect(await (await send(request(deliveries))).json()).toMatchObject({ outcome: "unchanged", deliveries: 2 });
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const [saved] = await new DenmarkSiriStore(state.storage).load(snapshot, siriAt(1_000));
      expect(saved?.calls.map(call => call.stopPointRef)).toEqual(["8601309", "8601770"]);
    });
  });

  it.each([[], Array.from({ length: 15 }, () => siriDelivery()), [siriDelivery(), "<Siri>"],
    [siriDelivery(), siriDelivery([siriJourney({ observedAt: siriAt(300_000) })], siriAt(300_000))]].map(deliveries => ({ deliveries })))
    ("rejects the whole invalid batch without any partial durable publication", async ({ deliveries }) => {
      expect((await send(request(deliveries))).status).toBe(400);
      expect(await runInDurableObject(env.WATCHER.getByName("global"), (_instance, state) => state.storage.list({ prefix }))).toEqual(new Map());
    });

  it("preserves authentication and bounds decoded XML independently of JSON envelope size", async () => {
    expect((await send(request([siriDelivery()], { authorization: "Bearer wrong" }))).status).toBe(401);
    expect((await send(request([" ".repeat(denmarkSiriBatchLimits.xmlBytes + 1)]))).status).toBe(400);
    expect((await send(request([siriDelivery()], { "content-length": String(denmarkSiriBatchLimits.bodyBytes + 1) }))).status).toBe(413);
    const base = request([siriDelivery()]);
    const stream = new ReadableStream<Uint8Array>({ start(controller) {
      controller.enqueue(new Uint8Array(denmarkSiriBatchLimits.bodyBytes + 1)); controller.close();
    } });
    const headers = new Headers(base.headers); headers.set("content-length", "1");
    expect((await send(new Request(base, { body: stream, headers }) as Input)).status).toBe(413);
    expect((await send(new Request(base, { body: new Uint8Array([0xff]).buffer }) as Input)).status).toBe(400);
    expect((await send(new Request(base, { body: "{\"deliveries\":" }) as Input)).status).toBe(400);
  });

  it("waits for the whole batch RPC, and never ACKs a failed durable transaction", async () => {
    let complete!: (value: Awaited<ReturnType<TrainTrackerWatcher["updateDenmarkSiriBatch"]>>) => void;
    const update = vi.fn(() => new Promise<Awaited<ReturnType<TrainTrackerWatcher["updateDenmarkSiriBatch"]>>>(resolve => { complete = resolve; }));
    let finished = false;
    const pending = handleDenmarkSiriRefresh(request([siriDelivery()]), {
      updateDenmarkSiri: vi.fn(), updateDenmarkSiriBatch: update,
    }).then(response => { finished = true; return response; });
    await vi.waitFor(() => expect(update).toHaveBeenCalledOnce());
    expect(finished).toBe(false);
    complete({ accepted: true, source: "denmark-siri", outcome: "stored", deliveries: 1, ignoredStale: 0, journeys: 1, calls: 1 });
    expect((await pending).status).toBe(200);
    const failed = await handleDenmarkSiriRefresh(request([siriDelivery()]), {
      updateDenmarkSiri: vi.fn(), updateDenmarkSiriBatch: async () => { throw new Error("durable failure"); },
    });
    expect(failed.status).toBe(500); expect(await failed.json()).toEqual({ error: "publication_failed" });
  });

  it("measures fifteen actual KV puts for fourteen distinct journeys and zero read/duplicate writes", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const scoped = `batch-cost:${crypto.randomUUID()}`;
      const cost = { puts: 0, deletes: 0 }, storage = countWrites(state.storage, cost);
      const deliveries = Array.from({ length: 14 }, (_, index) => siriDelivery([
        siriJourney({ reference: `batch-${index}`, trainNumber: String(2360 + index) }),
      ]));
      const store = new DenmarkSiriStore(storage, scoped);
      await store.ingestBatch(deliveries, siriClock); expect(cost).toEqual({ puts: 15, deletes: 0 });
      expect(await store.ingestBatch(deliveries, siriAt(1_000))).toMatchObject({ outcome: "unchanged" });
      expect((await store.health(siriAt(301_000))).ready).toBe(false);
      expect(await store.load(snapshot, siriAt(301_000))).toEqual([]);
      expect(cost).toEqual({ puts: 15, deletes: 0 });
    });
  });

  it("coalesces fourteen forecasts for one journey into two actual KV puts", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const scoped = `batch-coalesce:${crypto.randomUUID()}`, cost = { puts: 0, deletes: 0 };
      const deliveries = Array.from({ length: 14 }, (_, index) => siriDelivery([
        siriJourney({ observedAt: siriAt(index * 1_000), calls: [siriCall(`86${String(index).padStart(5, "0")}`)] }),
      ], siriAt(index * 1_000)));
      await new DenmarkSiriStore(countWrites(state.storage, cost), scoped).ingestBatch(deliveries, siriAt(14_000));
      expect(cost).toEqual({ puts: 2, deletes: 0 });
      const [saved] = await new DenmarkSiriStore(state.storage, scoped).load(snapshot, siriAt(15_000));
      expect(saved?.calls).toHaveLength(14);
      expect(saved).toMatchObject({ observedAt: siriAt(13_000), receivedAt: siriAt(14_000) });
    });
  });

  it("serializes a batch racing a single publication without losing any independently newer call", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const scoped = `batch-concurrent:${crypto.randomUUID()}`;
      await Promise.all([
        new DenmarkSiriStore(state.storage, scoped).ingestBatch([
          siriDelivery([siriJourney({ observedAt: siriAt(10_000), calls: [siriCall("8601309")] })], siriAt(10_000)),
          siriDelivery([siriJourney({ observedAt: siriAt(30_000), calls: [siriCall("8601770")] })], siriAt(30_000)),
        ], siriAt(31_000)),
        new DenmarkSiriStore(state.storage, scoped).ingest(
          siriDelivery([siriJourney({ observedAt: siriAt(20_000), calls: [siriCall("8600223")] })], siriAt(20_000)), siriAt(31_000)),
      ]);
      const [saved] = await new DenmarkSiriStore(state.storage, scoped).load(snapshot, siriAt(32_000));
      expect(saved?.calls.map(call => call.stopPointRef)).toEqual(["8600223", "8601309", "8601770"]);
      expect(saved?.observedAt).toBe(siriAt(30_000));
    });
  });

  it("rolls back every member if the batch transaction fails after its writes", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const scoped = `batch-rollback:${crypto.randomUUID()}`;
      await new DenmarkSiriStore(state.storage, scoped).ingest(siriDelivery(), siriClock);
      const before = await state.storage.list({ prefix: scoped });
      const storage: DenmarkSiriStorage = { transaction: work => state.storage.transaction(async tx => {
        await work(tx); throw new Error("forced rollback");
      }) };
      await expect(new DenmarkSiriStore(storage, scoped).ingestBatch([
        siriDelivery([siriJourney({ observedAt: siriAt(20_000), calls: [siriCall("8601770")] })], siriAt(20_000)),
        siriDelivery([siriJourney({ reference: "second" })]),
      ], siriAt(21_000))).rejects.toThrow("forced rollback");
      expect(await state.storage.list({ prefix: scoped })).toEqual(before);
      expect((await new DenmarkSiriStore(state.storage, scoped).load(snapshot, siriAt(22_000)))[0]?.calls).toHaveLength(1);
    });
  });
});
