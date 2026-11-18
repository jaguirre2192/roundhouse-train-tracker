import { transit_realtime } from "gtfs-realtime-bindings";
import { describe, expect, it, vi } from "vitest";
import { ProviderRequestBudget } from "../src/cloudflare/provider-request-budget.js";
import { RegionalFeedStore } from "../src/cloudflare/regional-feed-store.js";
import { MalaysiaVehiclePositionOverlay } from "../src/providers/malaysia-vehicle-position.js";
import type { MalaysiaCachedFeed, MalaysiaVehicleFeedOptions } from "../src/providers/malaysia-vehicle-feed.js";
import { response, snapshot } from "./helpers/malaysia-vehicle-position.js";

const baseTime = Date.parse("2026-07-21T12:55:30Z");
function storage() {
  const values = new Map<string, unknown>();
  let queue = Promise.resolve();
  const get = async <T>(key: string): Promise<T | undefined> => structuredClone(values.get(key)) as T | undefined;
  const transaction = <T>(work: (tx: { get<V>(key: string): Promise<V | undefined>; put(key: string, value: unknown): Promise<void> }) => Promise<T>) => {
    const result = queue.then(() => work({ get,
      put: async (key, value) => { values.set(key, structuredClone(value)); } }));
    queue = result.then(() => undefined, () => undefined);
    return result;
  };
  return { get, values, transaction };
}
function runtime(db: ReturnType<typeof storage>, now: () => number): MalaysiaVehicleFeedOptions {
  const budget = new ProviderRequestBudget(db, "malaysia-quota", Number.MAX_SAFE_INTEGER, 30_000, now);
  const cache = new RegionalFeedStore(db, "malaysia-feed", now);
  return { reserveRequest: () => budget.reserve(), readFeed: () => cache.load(), writeFeed: value => cache.save(value) };
}
function overlay(fetcher: typeof fetch, options: MalaysiaVehicleFeedOptions, now = () => baseTime) {
  return new MalaysiaVehiclePositionOverlay("https://example.test/persistent-ktmb.pb", fetcher, () => new Date(now()), options);
}

async function cachedFeed(fetchedAt = baseTime): Promise<MalaysiaCachedFeed> {
  return { fetchedAt, bytes: new Uint8Array(await response().arrayBuffer()) };
}

describe("Malaysia persistent quota and feed", () => {
  it("preserves original observation and poll times through owner recreation", async () => {
    const db = storage(); let now = baseTime, calls = 0;
    const fetcher: typeof fetch = async () => { calls += 1; return response(); };
    const create = () => overlay(fetcher, runtime(db, () => now), () => now);
    const first = await create().positionUpdates(snapshot());
    expect(first[0]?.asOf).toBe("2026-07-21T12:54:37.000Z");
    now += 20_000;
    expect(await create().positionUpdates(snapshot())).toEqual(first);
    expect(calls).toBe(1);
    expect((await db.get<MalaysiaCachedFeed>("malaysia-feed"))?.fetchedAt).toBe(baseTime);
    now += 10_000;
    expect(await create().positionUpdates(snapshot())).toHaveLength(1);
    expect(calls).toBe(2);
    expect(db.values.size).toBe(2);
  });

  it("allows only one request across simultaneous independent owner instances", async () => {
    const db = storage(); let calls = 0, finish!: (value: Response) => void;
    const fetcher: typeof fetch = async () => {
      calls += 1; return new Promise(resolve => { finish = resolve; });
    };
    const pending = Array.from({ length: 12 }, () => overlay(fetcher, runtime(db, () => baseTime)).positionUpdates(snapshot()));
    await vi.waitFor(() => expect(calls).toBe(1));
    finish(response());
    const values = await Promise.all(pending);
    expect(calls).toBe(1);
    expect(values.filter(value => value.length > 0)).toHaveLength(1);
  });

  it("retains the globally reserved cooldown after a failed request and owner reset", async () => {
    const db = storage(); let now = baseTime, calls = 0;
    const fetcher: typeof fetch = async () => { calls += 1; return new Response(null, { status: 503 }); };
    const create = () => overlay(fetcher, runtime(db, () => now), () => now);
    await expect(create().positionUpdates(snapshot())).rejects.toThrow("503");
    now += 29_999;
    expect(await create().positionUpdates(snapshot())).toEqual([]);
    expect(calls).toBe(1);
    now += 1;
    await expect(create().positionUpdates(snapshot())).rejects.toThrow("503");
    expect(calls).toBe(2);
  });

  it("uses a previously cached point while quota is denied without renewing point age", async () => {
    const saved = await cachedFeed(baseTime - 90_000), fetcher = vi.fn<typeof fetch>();
    const value = await overlay(fetcher, { reserveRequest: async () => false, readFeed: async () => saved }).positionUpdates(snapshot());
    expect(value[0]?.asOf).toBe("2026-07-21T12:54:37.000Z");
    expect(fetcher).not.toHaveBeenCalled();
  });

  it.each(["read", "reserve"])("fails closed on persistent %s failure", async (phase) => {
    const fetcher = vi.fn<typeof fetch>();
    const fail = async (): Promise<never> => { throw new Error("storage failed"); };
    const options: MalaysiaVehicleFeedOptions = phase === "read" ? { readFeed: fail } : { reserveRequest: fail };
    await expect(overlay(fetcher, options).positionUpdates(snapshot())).rejects.toThrow("storage failed");
    expect(fetcher).not.toHaveBeenCalled();
  });

  it.each(["expired", "future", "oversized", "malformed"])("rejects %s persistent bytes when quota is denied", async (kind) => {
    const value = await cachedFeed();
    if (kind === "expired") value.fetchedAt -= 240_001;
    if (kind === "future") value.fetchedAt += 1;
    if (kind === "oversized") value.bytes = new Uint8Array(96 * 1_024 + 1);
    if (kind === "malformed") value.bytes = new Uint8Array([255]);
    const fetcher = vi.fn<typeof fetch>();
    expect(await overlay(fetcher, { readFeed: async () => value, reserveRequest: async () => false }).positionUpdates(snapshot())).toEqual([]);
    expect(fetcher).not.toHaveBeenCalled();
  });

  it("does not refresh a stale vehicle timestamp from a recent persisted fetch", async () => {
    const old = response(vehicle => { vehicle.timestamp = Math.floor(baseTime / 1_000) - 301; });
    const value = { fetchedAt: baseTime, bytes: new Uint8Array(await old.arrayBuffer()) };
    expect(await overlay(vi.fn<typeof fetch>(), { readFeed: async () => value }).positionUpdates(snapshot())).toEqual([]);
  });

  it("persists an empty replacement feed so disappeared trains do not return after reset", async () => {
    const db = storage(); let now = baseTime, calls = 0;
    const empty = transit_realtime.FeedMessage.encode({ header: { gtfsRealtimeVersion: "2.0" }, entity: [] }).finish();
    const fetcher: typeof fetch = async () => {
      calls += 1; return calls === 1 ? response() : new Response(new Uint8Array(empty).buffer);
    };
    const create = () => overlay(fetcher, runtime(db, () => now), () => now);
    expect(await create().positionUpdates(snapshot())).toHaveLength(1);
    now += 30_000;
    expect(await create().positionUpdates(snapshot())).toEqual([]);
    now += 1_000;
    expect(await create().positionUpdates(snapshot())).toEqual([]);
    expect(calls).toBe(2);
  });

  it("uses original cached points on upstream failure and tolerates cache-write failure", async () => {
    const previous = await cachedFeed(baseTime - 30_000);
    expect(await overlay(async () => new Response(null, { status: 503 }), {
      readFeed: async () => previous, reserveRequest: async () => true,
    }).positionUpdates(snapshot())).toHaveLength(1);
    expect(await overlay(async () => response(), {
      reserveRequest: async () => true, writeFeed: async () => { throw new Error("write failed"); },
    }).positionUpdates(snapshot())).toHaveLength(1);
  });

  it("rejects oversized network responses before persisting them", async () => {
    const writeFeed = vi.fn<(value: MalaysiaCachedFeed) => Promise<void>>();
    await expect(overlay(async () => new Response(new Uint8Array(2 * 1_024 * 1_024 + 1)), { writeFeed })
      .positionUpdates(snapshot())).rejects.toThrow("byte limit");
    expect(writeFeed).not.toHaveBeenCalled();
  });
});
