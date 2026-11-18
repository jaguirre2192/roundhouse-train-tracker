import { env, runInDurableObject } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { RegionalIndexMaintenance, regionalIndexMaintenanceKey } from "../src/cloudflare/regional-index-maintenance.js";
import { RailIndexStore } from "../src/cloudflare/rail-index-store.js";
import type { RegionalRailIndex } from "../src/providers/trafiklab-regional-index.js";

const base = Date.parse("2026-11-13T08:45:00Z");
const day = 86_400_000;
function index(at = base): RegionalRailIndex {
  const midnight = Math.floor(at / day) * day;
  const feedVersion = new Date(midnight).toISOString().slice(0, 10);
  return { operator: "skane", feedVersion, generatedAt: new Date(midnight).toISOString(),
    expiresAt: new Date(midnight + 7 * day).toISOString(), sourceHashes: { regional: "a".repeat(64) },
    stations: [["902201", "740001", "Malmö Centralstation", 55.609, 13.001, "1"],
      ["902202", "740002", "Lund Centralstation", 55.705, 13.187, "2"]],
    services: [[feedVersion.replaceAll("-", "")]],
    trips: [["121123100", "1231", 0, [[0, 1, 3_600, 3_600], [1, 2, 7_200, 7_200]]]],
  };
}

beforeEach(async () => {
  await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
    await state.storage.delete(regionalIndexMaintenanceKey);
    const keys = [...(await state.storage.list({ prefix: "rail-index:skane:" })).keys()];
    if (keys.length > 0) await state.storage.delete(keys);
  });
});

describe("daily regional index maintenance in Durable Object storage", () => {
  it("waits until the UTC start time, reserves before loading, and persists across instances", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      let now = Date.parse("2026-11-13T08:42:59.999Z"), loads = 0;
      const create = () => new RegionalIndexMaintenance(state.storage, {
        now: () => new Date(now), loadIndex: async () => {
          loads += 1;
          expect(await state.storage.get(regionalIndexMaintenanceKey)).toMatchObject({
            lastAttemptUTCday: new Date(now).toISOString().slice(0, 10), outcome: "running",
          });
          return index(now);
        },
      });
      expect((await create().run()).outcome).toBe("not-attempted");
      expect(await state.storage.get(regionalIndexMaintenanceKey)).toBeUndefined();
      now += 1;
      expect(await create().run()).toMatchObject({ outcome: "stored", feedVersion: "2026-11-13",
        stationCount: 2, serviceCount: 1, tripCount: 1 });
      now += 41_000;
      expect((await create().run()).outcome).toBe("stored");
      expect(loads).toBe(1);
      now -= day;
      expect((await create().run()).outcome).toBe("stored");
      expect(loads).toBe(1);
      now = Date.parse("2026-11-14T08:45:00Z");
      expect((await create().run()).feedVersion).toBe("2026-11-14");
      expect(loads).toBe(2);
    });
  });

  it("shares pending work and atomically permits only one loader across concurrent objects", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      let release!: (value: unknown) => void, started!: () => void, loads = 0;
      const loading = new Promise<unknown>(resolve => { release = resolve; });
      const didStart = new Promise<void>(resolve => { started = resolve; });
      const options = { now: () => new Date(base), loadIndex: async () => { loads += 1; started(); return loading; } };
      const maintenance = new RegionalIndexMaintenance(state.storage, options);
      const first = maintenance.run();
      expect(maintenance.run()).toBe(first);
      await didStart;
      const others = await Promise.all(Array.from({ length: 8 }, () => new RegionalIndexMaintenance(state.storage, options).run()));
      expect(others.every(result => result.outcome === "running")).toBe(true);
      expect(loads).toBe(1);
      release(index());
      expect((await first).outcome).toBe("stored");
      expect((await maintenance.health()).outcome).toBe("stored");
    });
  });

  it("counts failure as today's attempt, preserves expiry, and exposes no provider error text", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const store = new RailIndexStore(state.storage, () => new Date(base));
      const previous = index(base - day);
      await store.save(previous);
      let loads = 0;
      const options = { now: () => new Date(base), loadIndex: async () => {
        loads += 1; throw new Error("https://provider.test/?key=private-test-secret");
      } };
      const maintenance = new RegionalIndexMaintenance(state.storage, options);
      expect((await maintenance.run()).outcome).toBe("failed");
      expect(await new RegionalIndexMaintenance(state.storage, options).run()).toEqual(await maintenance.health());
      expect(loads).toBe(1);
      expect(await store.load()).toEqual(previous);
      expect(JSON.stringify(await maintenance.health())).not.toMatch(/provider|secret|https/u);
    });
  });

  it("aborts a timed out load and cannot publish a late result or retry the same day", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const store = new RailIndexStore(state.storage, () => new Date(base));
      const previous = index(base - day);
      await store.save(previous);
      let receivedSignal: AbortSignal | undefined, release!: (value: unknown) => void, loads = 0;
      const options = { now: () => new Date(base), timeoutMs: 10, loadIndex: async (signal: AbortSignal) => {
        receivedSignal = signal; loads += 1; return new Promise(resolve => { release = resolve; });
      } };
      expect((await new RegionalIndexMaintenance(state.storage, options).run()).outcome).toBe("timeout");
      expect(receivedSignal?.aborted).toBe(true);
      release(index());
      await Promise.resolve();
      expect((await new RegionalIndexMaintenance(state.storage, options).run()).outcome).toBe("timeout");
      expect(loads).toBe(1);
      expect(await store.load()).toEqual(previous);
    });
  });

  it("does not replace a valid index with invalid or older input, or extend unchanged expiry", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      let now = base;
      const store = new RailIndexStore(state.storage, () => new Date(now));
      const previous = index();
      await store.save(previous);
      for (const [value, outcome] of [[{}, "invalid"], [index(base - day), "older"], [previous, "unchanged"]] as const) {
        const result = await new RegionalIndexMaintenance(state.storage, {
          now: () => new Date(now), loadIndex: async () => value,
        }).run();
        expect(result.outcome).toBe(outcome);
        expect(await store.load()).toEqual(previous);
        now += day;
      }
    });
  });

  it("includes a stalled publisher in the deadline and does not renew its reservation", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      let loads = 0, publishes = 0, signal: AbortSignal | undefined;
      const options = { now: () => new Date(base), timeoutMs: 10,
        loadIndex: async () => { loads += 1; return index(); },
        publishIndex: async (_index: RegionalRailIndex, supplied: AbortSignal): Promise<never> => {
          publishes += 1; signal = supplied;
          return new Promise((_resolve, reject) => supplied.addEventListener("abort", () => reject(new Error("aborted")), { once: true }));
        },
      };
      const maintenance = new RegionalIndexMaintenance(state.storage, options);
      expect((await maintenance.run()).outcome).toBe("timeout");
      expect(signal?.aborted).toBe(true);
      expect((await new RegionalIndexMaintenance(state.storage, options).run()).outcome).toBe("timeout");
      expect(loads).toBe(1);
      expect(publishes).toBe(1);
      expect(await new RailIndexStore(state.storage).load()).toBeNull();
    });
  });

  it("fails closed on corrupt or future reservation state without loading", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      let loads = 0;
      const options = { now: () => new Date(base), loadIndex: async () => { loads += 1; return index(); } };
      await state.storage.put(regionalIndexMaintenanceKey, { lastAttemptUTCday: "2026-11-99", outcome: "running" });
      const invalid = new RegionalIndexMaintenance(state.storage, options);
      expect((await invalid.run()).outcome).toBe("state-invalid");
      expect((await invalid.health()).outcome).toBe("state-invalid");
      await state.storage.delete(regionalIndexMaintenanceKey);
      await new RegionalIndexMaintenance(state.storage, { ...options, now: () => new Date(base + day) }).run();
      expect(loads).toBe(1);
      await new RegionalIndexMaintenance(state.storage, options).run();
      expect(loads).toBe(1);
    });
  });

  it("never starts loading if the reservation transaction cannot commit", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      let loads = 0;
      const failing = new Proxy(state.storage, {
        get(target, property) {
          if (property === "transaction") return <T>(work: (transaction: DurableObjectTransaction) => Promise<T>) =>
            target.transaction(async transaction => { await work(transaction); throw new Error("abort"); });
          const value = Reflect.get(target, property);
          return typeof value === "function" ? value.bind(target) : value;
        },
      });
      const result = await new RegionalIndexMaintenance(failing, {
        now: () => new Date(base), loadIndex: async () => { loads += 1; return index(); },
      }).run();
      expect(result.outcome).toBe("storage-error");
      expect(loads).toBe(0);
      expect(await state.storage.get(regionalIndexMaintenanceKey)).toBeUndefined();
    });
  });

  it("preserves an older failed reservation with unknown diagnostics and never infers retry eligibility", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const legacy = { lastAttemptUTCday: "2026-11-13", lastAttemptAt: "2026-11-13T08:44:00.000Z",
        completedAt: "2026-11-13T08:44:00.036Z", outcome: "failed", feedVersion: null,
        stationCount: null, serviceCount: null, tripCount: null };
      await state.storage.put(regionalIndexMaintenanceKey, legacy);
      let loads = 0;
      const maintenance = new RegionalIndexMaintenance(state.storage, { now: () => new Date(base),
        loadIndex: async () => { loads += 1; return index(); } });
      expect(await maintenance.run()).toMatchObject({ outcome: "failed", diagnostics: {
        phase: null, httpStatus: null, redirectStatus: null, downloadBytes: null, downloadComplete: null,
      } });
      expect(loads).toBe(0);
      expect(await state.storage.get(regionalIndexMaintenanceKey)).toEqual(legacy);
    });
  });

  it("allows one operator-authorized legacy failure retry and preserves the original record", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      const legacy = { lastAttemptUTCday: "2026-11-13", lastAttemptAt: "2026-11-13T08:44:00.000Z",
        completedAt: "2026-11-13T08:44:00.036Z", outcome: "failed", feedVersion: null,
        stationCount: null, serviceCount: null, tripCount: null };
      await state.storage.put(regionalIndexMaintenanceKey, legacy);
      let loads = 0;
      const options = { now: () => new Date(base), loadIndex: async () => { loads += 1; return index(); } };
      const result = await new RegionalIndexMaintenance(state.storage, options).run(legacy.lastAttemptAt);
      expect(result).toMatchObject({ outcome: "stored", attemptsToday: 2, previousAttempt: legacy });
      expect(result.previousAttempt).not.toHaveProperty("previousAttempt");
      await expect(new RegionalIndexMaintenance(state.storage, options).run(legacy.lastAttemptAt)).rejects.toThrow("retry is not allowed");
      expect((await new RegionalIndexMaintenance(state.storage, options).run()).attemptsToday).toBe(2);
      expect(loads).toBe(1);
      expect((await new RegionalIndexMaintenance(state.storage, options).health()).previousAttempt).toMatchObject(legacy);
    });
  });

  it("reserves the sole retry atomically across recreated objects and denies an in-flight replay", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      let now = base, loads = 0;
      const first = await new RegionalIndexMaintenance(state.storage, { now: () => new Date(now),
        loadIndex: async () => { loads += 1; throw new Error("first failure"); } }).run();
      now += 1_000;
      let release!: (value: unknown) => void, started!: () => void;
      const didStart = new Promise<void>(resolve => { started = resolve; });
      const options = { now: () => new Date(now), loadIndex: async () => {
        loads += 1; started(); return new Promise(resolve => { release = resolve; });
      } };
      const maintenance = new RegionalIndexMaintenance(state.storage, options);
      const retry = maintenance.run(first.lastAttemptAt!);
      await expect(maintenance.run(first.lastAttemptAt!)).rejects.toThrow("retry is not allowed");
      await didStart;
      const concurrent = await Promise.allSettled(Array.from({ length: 8 }, () =>
        new RegionalIndexMaintenance(state.storage, options).run(first.lastAttemptAt!)));
      expect(concurrent.every(result => result.status === "rejected")).toBe(true);
      expect(loads).toBe(2);
      release(index());
      expect((await retry).attemptsToday).toBe(2);
    });
  });

  it("rejects old-day, mismatched, successful, unchanged, and running retry tokens", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      let now = base, loads = 0;
      const options = { now: () => new Date(now), loadIndex: async () => { loads += 1; return index(now); } };
      const result = await new RegionalIndexMaintenance(state.storage, options).run();
      for (const outcome of ["stored", "unchanged", "running"]) {
        await state.storage.put(regionalIndexMaintenanceKey, { ...result, outcome });
        await expect(new RegionalIndexMaintenance(state.storage, options).run(result.lastAttemptAt!)).rejects.toThrow("retry is not allowed");
      }
      await state.storage.put(regionalIndexMaintenanceKey, { ...result, outcome: "failed" });
      await expect(new RegionalIndexMaintenance(state.storage, options).run("2026-11-13T08:44:59.000Z")).rejects.toThrow("retry is not allowed");
      now += day;
      await expect(new RegionalIndexMaintenance(state.storage, options).run(result.lastAttemptAt!)).rejects.toThrow("retry is not allowed");
      expect(loads).toBe(1);
      expect((await new RegionalIndexMaintenance(state.storage, options).run()).attemptsToday).toBe(1);
      expect(loads).toBe(2);
    });
  });

  it("also counts a failed timeout recovery as the second and final attempt", async () => {
    await runInDurableObject(env.WATCHER.getByName("global"), async (_instance, state) => {
      let now = base, loads = 0;
      const first = await new RegionalIndexMaintenance(state.storage, { now: () => new Date(now), timeoutMs: 5,
        loadIndex: async () => { loads += 1; return new Promise(() => {}); } }).run();
      expect(first.outcome).toBe("timeout");
      now += 1_000;
      const options = { now: () => new Date(now), loadIndex: async () => { loads += 1; throw new Error("still unavailable"); } };
      const retry = await new RegionalIndexMaintenance(state.storage, options).run(first.lastAttemptAt!);
      expect(retry).toMatchObject({ attemptsToday: 2, outcome: "failed", previousAttempt: { outcome: "timeout" } });
      await expect(new RegionalIndexMaintenance(state.storage, options).run(retry.lastAttemptAt!)).rejects.toThrow("retry is not allowed");
      expect(loads).toBe(2);
    });
  });
});
