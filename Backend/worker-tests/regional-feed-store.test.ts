import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { RegionalFeedStore } from "../src/cloudflare/regional-feed-store.js";

const timestamp = Date.parse("2026-11-13T20:00:00Z");
const bytes = new Uint8Array([10, 3, 50, 46, 48]);

describe("regional rail feed in Durable Object storage", () => {
  it("survives separate store instances and copies only a bounded view", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const key = `test-regional-feed:${crypto.randomUUID()}`;
      const largeBuffer = new Uint8Array(2 * 1_024 * 1_024);
      largeBuffer.set(bytes, 100);
      const value = { fetchedAt: timestamp, bytes: largeBuffer.subarray(100, 100 + bytes.length) };
      await new RegionalFeedStore(state.storage, key, () => timestamp).save(value);
      largeBuffer.fill(0);
      const second = new RegionalFeedStore(state.storage, key, () => timestamp + 41_000);
      const loaded = await second.load();
      expect(loaded).toEqual({ fetchedAt: timestamp, bytes });
      expect(loaded?.bytes.buffer.byteLength).toBe(bytes.length);
      loaded!.bytes.fill(0);
      expect(await new RegionalFeedStore(state.storage, key, () => timestamp + 42_000).load())
        .toEqual({ fetchedAt: timestamp, bytes });
      expect((await state.storage.list({ prefix: key })).size).toBe(1);
    });
  });

  it("expires using the original fetch time and never extends age on save", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const key = `test-regional-feed:${crypto.randomUUID()}`;
      let now = timestamp;
      const store = new RegionalFeedStore(state.storage, key, () => now);
      await store.save({ fetchedAt: timestamp, bytes });
      now += 240_000;
      const lastValid = await store.load();
      expect(lastValid?.fetchedAt).toBe(timestamp);
      await store.save(lastValid!);
      now += 1;
      expect(await store.load()).toBeNull();
      await store.save(lastValid!);
      expect((await state.storage.get<{ fetchedAt: number }>(key))?.fetchedAt).toBe(timestamp);
      expect(await store.load()).toBeNull();
    });
  });

  it("fails closed on future timestamps and clock rollback", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const key = `test-regional-feed:${crypto.randomUUID()}`;
      let now = timestamp;
      const store = new RegionalFeedStore(state.storage, key, () => now);
      await store.save({ fetchedAt: timestamp + 1, bytes });
      expect(await state.storage.get(key)).toBeUndefined();
      await store.save({ fetchedAt: timestamp, bytes });
      now -= 1;
      expect(await store.load()).toBeNull();
      now = Number.NaN;
      expect(await store.load()).toBeNull();
      await store.save({ fetchedAt: timestamp, bytes });
      expect((await state.storage.get<{ fetchedAt: number }>(key))?.fetchedAt).toBe(timestamp);
    });
  });

  it("rejects corrupt, empty, oversized, or expired persisted values", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const key = `test-regional-feed:${crypto.randomUUID()}`;
      const invalid = [null, [], {}, { fetchedAt: Number.NaN, bytes }, { fetchedAt: Infinity, bytes },
        { fetchedAt: -1, bytes }, { fetchedAt: String(timestamp), bytes }, { fetchedAt: timestamp + 1, bytes },
        { fetchedAt: timestamp - 240_001, bytes }, { fetchedAt: timestamp, bytes: [...bytes] },
        { fetchedAt: timestamp, bytes: new DataView(bytes.buffer) },
        { fetchedAt: timestamp, bytes: new Uint8Array() },
        { fetchedAt: timestamp, bytes: new Uint8Array(96 * 1_024 + 1) }];
      for (const value of invalid) {
        await state.storage.put(key, value);
        expect(await new RegionalFeedStore(state.storage, key, () => timestamp).load()).toBeNull();
      }
    });
  });

  it("accepts the maximum bounded payload and ignores invalid replacement writes", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const key = `test-regional-feed:${crypto.randomUUID()}`;
      const store = new RegionalFeedStore(state.storage, key, () => timestamp);
      const maximum = new Uint8Array(96 * 1_024).fill(7);
      await store.save({ fetchedAt: timestamp, bytes: maximum });
      expect((await store.load())?.bytes).toEqual(maximum);
      for (const replacement of [new Uint8Array(), new Uint8Array(maximum.length + 1)]) {
        await store.save({ fetchedAt: timestamp, bytes: replacement });
        expect((await store.load())?.bytes).toEqual(maximum);
      }
    });
  });

  it("atomically retains the newest original fetch time across concurrent writers", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const key = `test-regional-feed:${crypto.randomUUID()}`;
      const create = () => new RegionalFeedStore(state.storage, key, () => timestamp);
      await Promise.all([10, 0, 40, 20].map(age => create().save({
        fetchedAt: timestamp - age * 1_000, bytes: new Uint8Array([age + 1]),
      })));
      await create().save({ fetchedAt: timestamp - 1, bytes });
      await create().save({ fetchedAt: timestamp, bytes });
      expect(await create().load()).toEqual({ fetchedAt: timestamp, bytes: new Uint8Array([1]) });
    });
  });

  it("replaces expired or corrupt persisted entries with a fresh valid feed", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const key = `test-regional-feed:${crypto.randomUUID()}`;
      const store = new RegionalFeedStore(state.storage, key, () => timestamp);
      for (const previous of [{ fetchedAt: timestamp - 240_001, bytes },
        { fetchedAt: timestamp + 1, bytes: [] }]) {
        await state.storage.put(key, previous);
        expect(await store.load()).toBeNull();
        await store.save({ fetchedAt: timestamp, bytes });
        expect(await store.load()).toEqual({ fetchedAt: timestamp, bytes });
      }
    });
  });

  it("propagates storage failures and preserves the previous value on rollback", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const key = `test-regional-feed:${crypto.randomUUID()}`;
      await new RegionalFeedStore(state.storage, key, () => timestamp).save({ fetchedAt: timestamp - 1, bytes });
      const failingStorage = {
        get: async <T>(): Promise<T | undefined> => { throw new Error("read failed"); },
        transaction: <T>(work: (transaction: DurableObjectTransaction) => Promise<T>): Promise<T> =>
          state.storage.transaction(async (transaction) => {
            await work(transaction);
            throw new Error("transaction aborted");
          }),
      };
      const failing = new RegionalFeedStore(failingStorage, key, () => timestamp);
      await expect(failing.load()).rejects.toThrow("read failed");
      await expect(failing.save({ fetchedAt: timestamp, bytes: new Uint8Array([99]) }))
        .rejects.toThrow("transaction aborted");
      expect(await new RegionalFeedStore(state.storage, key, () => timestamp).load())
        .toEqual({ fetchedAt: timestamp - 1, bytes });
    });
  });
});
