import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { ProviderRequestBudget } from "../src/cloudflare/provider-request-budget.js";

describe("provider allowance in Durable Object storage", () => {
  it("persists paired Silver cooldowns and the existing Bronze ledger in real storage", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const key = `silver-budget:${crypto.randomUUID()}`;
      let now = Date.parse("2026-11-16T18:00:00Z");
      await new ProviderRequestBudget(state.storage, key, 25_000, 120_000, () => now).reserve("positions");
      const create = () => new ProviderRequestBudget(state.storage, key, 5, 0, () => now, 30_000);
      now += 29_999;
      expect(await create().reserve("trip-updates")).toBe(false);
      now += 1;
      expect(await Promise.all([create().reserve("trip-updates"), create().reserve("positions")])).toEqual([true, true]);
      // Upstream failure after a reservation cannot make a recreated service
      // spend the allowance again while either lane is cooling down.
      now += 29_999;
      expect(await Promise.all([create().reserve("trip-updates"), create().reserve("positions")])).toEqual([false, false]);
      now += 1;
      expect(await Promise.all([create().reserve("trip-updates"), create().reserve("positions")])).toEqual([true, true]);
      now += 30_000;
      expect(await create().reserve("trip-updates")).toBe(false);
      expect(await state.storage.get(key)).toEqual({ lastReservedAt: now - 30_000, lastLane: "positions",
        days: { [String(Math.floor(now / 86_400_000))]: 5 },
        laneReservedAt: { "trip-updates": now - 30_000, positions: now - 30_000 } });
    });
  });

  it("alternates timing and GPS across sparse calls and recreated objects with one shared allowance", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const key = `paired-budget:${crypto.randomUUID()}`;
      let now = Date.parse("2026-11-13T21:00:00Z");
      const create = () => new ProviderRequestBudget(state.storage, key, 4, 120_000, () => now);
      for (const lane of ["trip-updates", "positions", "trip-updates", "positions"] as const) {
        const requests = await Promise.all([create().reserve("trip-updates"), create().reserve("positions")]);
        expect(requests).toEqual(lane === "trip-updates" ? [true, false] : [false, true]);
        now += 240_000;
      }
      expect(await create().reserve("trip-updates")).toBe(false);
      expect(await create().reserve("positions")).toBe(false);
    });
  });

  it("retains and extends provider Retry-After without consuming another reservation", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const key = `deferred-budget:${crypto.randomUUID()}`;
      let now = Date.parse("2026-11-13T21:00:00Z");
      const create = () => new ProviderRequestBudget(state.storage, key, Number.MAX_SAFE_INTEGER, 30_000, () => now);
      expect(await create().reserve()).toBe(true);
      await create().deferUntil(now + 120_000);
      await create().deferUntil(now + 60_000);
      now += 119_999;
      expect(await create().reserve()).toBe(false);
      now += 1;
      expect(await create().reserve()).toBe(true);
      const saved = await state.storage.get<{ days: Record<string, number> }>(key);
      expect(Object.values(saved!.days)).toEqual([2]);
    });
  });

  it("atomically reserves once and preserves the cooldown across budget instances", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const key = `test-budget:${crypto.randomUUID()}`;
      let now = Date.parse("2026-11-13T18:00:00Z");
      const create = () => new ProviderRequestBudget(state.storage, key, 25_000, 240_000, () => now);
      const results = await Promise.all(Array.from({ length: 12 }, () => create().reserve()));
      expect(results.filter(Boolean)).toHaveLength(1);
      expect(await state.storage.get(key)).toEqual({
        lastReservedAt: now, days: { [String(Math.floor(now / 86_400_000))]: 1 },
      });
      now += 239_999;
      expect(await create().reserve()).toBe(false);
      now += 1;
      expect(await create().reserve()).toBe(true);
      now -= 86_400_000;
      expect(await create().reserve()).toBe(false);
    });
  });

  it("keeps a reservation after upstream failure and fails closed on persisted corruption", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const key = `test-budget:${crypto.randomUUID()}`;
      let now = Date.parse("2026-11-13T18:00:00Z");
      const create = () => new ProviderRequestBudget(state.storage, key, 1, 240_000, () => now);
      let outboundCalls = 0;
      const request = async () => {
        if (!await create().reserve()) return;
        outboundCalls += 1;
        throw new Error("upstream unavailable");
      };
      await expect(request()).rejects.toThrow("upstream unavailable");
      now += 240_000;
      await request();
      expect(outboundCalls).toBe(1);
      await state.storage.put(key, { lastReservedAt: now - 240_000, days: [] });
      expect(await create().reserve()).toBe(false);
    });
  });

  it("does not grant a reservation when the real storage transaction rolls back", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const key = `test-budget:${crypto.randomUUID()}`;
      const now = Date.parse("2026-11-13T18:00:00Z");
      const failingStorage = {
        transaction: <T>(work: (transaction: DurableObjectTransaction) => Promise<T>): Promise<T> =>
          state.storage.transaction(async (transaction) => {
            await work(transaction);
            throw new Error("transaction aborted");
          }),
      };
      await expect(new ProviderRequestBudget(failingStorage, key, 1, 0, () => now).reserve())
        .rejects.toThrow("transaction aborted");
      expect(await state.storage.get(key)).toBeUndefined();
      expect(await new ProviderRequestBudget(state.storage, key, 1, 0, () => now).reserve()).toBe(true);
    });
  });
});
