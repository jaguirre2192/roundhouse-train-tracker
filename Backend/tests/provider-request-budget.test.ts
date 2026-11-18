import { describe, expect, it } from "vitest";
import { ProviderRequestBudget } from "../src/cloudflare/provider-request-budget.js";
import { tdxBudgetedFetch } from "../src/cloudflare/tdx-budgeted-fetch.js";

function storage() {
  const values = new Map<string, unknown>();
  let queue = Promise.resolve();
  const transaction = <T>(work: (tx: { get<V>(key: string): Promise<V | undefined>; put(key: string, value: unknown): Promise<void> }) => Promise<T>) => {
    const result = queue.then(() => work({ get: async <V>(key: string) => values.get(key) as V | undefined,
      put: async (key, value) => { values.set(key, value); } }));
    queue = result.then(() => undefined, () => undefined);
    return result;
  };
  return { values, transaction };
}

describe("TDX Basic account allowance", () => {
  const url = "https://tdx.transportdata.tw/api/basic/v3/Rail/TRA/StationLiveBoard";
  const key = "provider-quota:tdx-basic:v1";
  const success = async () => new Response(null, { status: 200 });

  it("shares the five-request rolling minute across parallel clients, failures and restarts", async () => {
    const db = storage();
    let time = Date.parse("2026-11-30T15:59:40Z"), calls = 0;
    const remote = async () => { calls += 1; return new Response(null, { status: 503 }); };
    const request = () => tdxBudgetedFetch(db, remote, () => time)(url);
    const results = await Promise.all(Array.from({ length: 8 }, request));
    expect(results.map(r => r.status)).toEqual([503, 503, 503, 503, 503, 429, 429, 429]);
    time += 20_000; // Midnight in Taipei does not erase the preceding rolling minute.
    expect((await request()).headers.get("Retry-After")).toBe("40");
    time += 40_000;
    expect((await request()).status).toBe(503);
    expect(calls).toBe(6);
    expect(db.values.get(key)).toMatchObject({ month: "2026-12", count: 1 });
  });

  it("keeps the free allowance through a restart and resets it at Taiwan's month boundary", async () => {
    const db = storage();
    let time = Date.parse("2026-11-30T15:59:00Z");
    db.values.set(key, { month: "2026-11", count: 2_699, blockedUntil: 0, latest: [time - 61_000] });
    const request = () => tdxBudgetedFetch(db, success, () => time)(url);
    expect((await request()).status).toBe(200);
    expect((await request()).status).toBe(429);
    time += 60_000;
    expect((await request()).status).toBe(200);
    expect(db.values.get(key)).toMatchObject({ month: "2026-12", count: 1 });
  });

  it("keeps an upstream Retry-After across service recreation", async () => {
    const db = storage();
    let time = Date.parse("2026-11-18T10:00:00Z");
    await tdxBudgetedFetch(db, async () => new Response(null, { status: 429, headers: { "Retry-After": "180" } }), () => time)(url);
    time += 60_000;
    const request = tdxBudgetedFetch(db, success, () => time);
    expect((await request(url)).headers.get("Retry-After")).toBe("120");
    time += 120_000;
    expect((await request(url)).status).toBe(200);
  });

  it("leaves damaged quota records in place and makes no upstream request", async () => {
    const db = storage();
    db.values.set(key, { count: -1 });
    const response = await tdxBudgetedFetch(db, () => { throw Error("unexpected request"); })(url);
    expect(response.status).toBe(429);
    expect(db.values.get(key)).toEqual({ count: -1 });
  });
});

describe("persistent provider request allowance", () => {
  it("permits a Silver pair together while persisting each lane's cooldown across failures and restarts", async () => {
    const db = storage(); let now = Date.parse("2026-11-16T18:00:00Z");
    const create = () => new ProviderRequestBudget(db, "silver", 1_800_000, 0, () => now, 30_000);
    // Reservations are spent before transport; errors cannot erase them.
    expect(await Promise.all([create().reserve("trip-updates"), create().reserve("positions")])).toEqual([true, true]);
    expect(await create().reserve()).toBe(false);
    now += 29_999;
    expect(await Promise.all([create().reserve("trip-updates"), create().reserve("positions")])).toEqual([false, false]);
    now += 1;
    expect(await Promise.all([create().reserve("trip-updates"), create().reserve("positions")])).toEqual([true, true]);
    expect(db.values.get("silver")).toMatchObject({ days: { [String(Math.floor(now / 86_400_000))]: 4 },
      laneReservedAt: { "trip-updates": now, positions: now } });
  });

  it("preserves Bronze usage, pending cooldown and fairness when adopting the Silver policy", async () => {
    const db = storage(); let now = Date.parse("2026-11-16T18:00:00Z");
    const key = "existing-key";
    expect(await new ProviderRequestBudget(db, key, 25_000, 120_000, () => now).reserve("trip-updates")).toBe(true);
    const create = () => new ProviderRequestBudget(db, key, 3, 0, () => now, 30_000);
    now += 29_999; expect(await create().reserve("positions")).toBe(false);
    now += 1; expect(await create().reserve("trip-updates")).toBe(false);
    expect(await create().reserve("positions")).toBe(true);
    expect(await create().reserve("trip-updates")).toBe(true);
    now += 30_000; expect(await create().reserve("positions")).toBe(false);
    expect(db.values.get(key)).toMatchObject({ days: { [String(Math.floor(now / 86_400_000))]: 3 } });
  });

  it.each([[], {}, { positions: -1 }, { unknown: 1 }, { positions: Infinity }])("rejects corrupt per-lane cooldown state", async (laneReservedAt) => {
    const db = storage(); const now = Date.parse("2026-11-16T18:00:00Z");
    db.values.set("silver", { lastReservedAt: now, days: { [String(Math.floor(now / 86_400_000))]: 1 }, laneReservedAt });
    expect(await new ProviderRequestBudget(db, "silver", 1_800_000, 0, () => now, 30_000).reserve("positions")).toBe(false);
  });

  it("alternates paired feeds across sparse polling and recreated services without resetting the shared cap", async () => {
    const db = storage(); let now = Date.parse("2026-11-13T18:00:00Z");
    const create = () => new ProviderRequestBudget(db, "paired", 4, 120_000, () => now);
    expect(await create().reserve("trip-updates")).toBe(true);
    expect(await create().reserve("positions")).toBe(false);
    now += 240_000;
    expect(await create().reserve("trip-updates")).toBe(false);
    expect(await create().reserve("positions")).toBe(true);
    now += 240_000;
    expect(await create().reserve("trip-updates")).toBe(true);
    expect(await create().reserve("positions")).toBe(false);
    now += 240_000;
    expect(await create().reserve("trip-updates")).toBe(false);
    expect(await create().reserve("positions")).toBe(true);
    now += 240_000;
    expect(await create().reserve("trip-updates")).toBe(false);
    expect(await create().reserve("positions")).toBe(false);
    expect(db.values.get("paired")).toMatchObject({ lastLane: "positions", days: { [String(Math.floor(now / 86_400_000))]: 4 } });
  });

  it("migrates an existing unlabeled reservation without erasing its count", async () => {
    const db = storage(); let now = Date.parse("2026-11-13T18:00:00Z");
    const create = () => new ProviderRequestBudget(db, "paired", 3, 120_000, () => now);
    expect(await create().reserve()).toBe(true);
    now += 120_000;
    expect(await create().reserve("positions")).toBe(true);
    now += 120_000;
    expect(await create().reserve("positions")).toBe(false);
    expect(await create().reserve("trip-updates")).toBe(true);
  });

  it("serializes concurrent requests and retains cooldown across service restarts", async () => {
    const db = storage(); let now = Date.parse("2026-11-13T18:00:00Z");
    const create = () => new ProviderRequestBudget(db, "regional", 25_000, 240_000, () => now);
    expect(await Promise.all([create().reserve(), create().reserve(), create().reserve()])).toEqual([true, false, false]);
    now += 239_999; expect(await create().reserve()).toBe(false);
    now += 1; expect(await create().reserve()).toBe(true);
  });

  it("does not reset a rolling allowance at a calendar-month boundary", async () => {
    const db = storage(); let now = Date.parse("2026-10-31T23:59:00Z");
    const budget = new ProviderRequestBudget(db, "regional", 2, 0, () => now);
    expect(await budget.reserve()).toBe(true); expect(await budget.reserve()).toBe(true);
    now += 120_000; expect(await budget.reserve()).toBe(false);
    now = Date.parse("2026-11-30T23:59:01Z"); expect(await budget.reserve()).toBe(false);
    now = Date.parse("2026-12-01T00:00:00Z"); expect(await budget.reserve()).toBe(true);
  });

  it("fails closed on clock rollback and corrupt stored counters", async () => {
    const db = storage(); let now = Date.parse("2026-11-13T18:00:00Z");
    const budget = new ProviderRequestBudget(db, "regional", 25_000, 240_000, () => now);
    expect(await budget.reserve()).toBe(true); now -= 86_400_000;
    expect(await budget.reserve()).toBe(false);
    db.values.set("regional", { lastReservedAt: 0, days: { invalid: -1 } });
    expect(await budget.reserve()).toBe(false);
  });

  it.each([[], new Date(), new Map(), {}, { "01": 1 }])("rejects a noncanonical stored day ledger", async (days) => {
    const db = storage(); db.values.set("regional", { lastReservedAt: 0, days });
    expect(await new ProviderRequestBudget(db, "regional").reserve()).toBe(false);
  });
});
