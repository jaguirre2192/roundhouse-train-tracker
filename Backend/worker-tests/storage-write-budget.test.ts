import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { initializeSchema } from "../src/cloudflare/schema.js";
import { SQLiteRuntimeStore } from "../src/cloudflare/sqlite-runtime-store.js";
import { SQLitePlatformObservationStore } from "../src/cloudflare/platform-observation-store.js";
import type { WatcherTickReport } from "../src/worker/watcher-cycle.js";
import type { TripSnapshot } from "../src/domain/snapshot.js";

const at = Date.parse("2026-11-17T12:00:00Z");
const empty: WatcherTickReport = { tripsClaimed: 0, tripsPolled: 0, providerFailures: 0,
  eventsCreated: 0, pushesClaimed: 0, pushesDelivered: 0, pushFailures: 0 };

function measured(target: SqlStorage) {
  let rows = 0;
  const sql = new Proxy(target, { get(target, property) {
    if (property !== "exec") return Reflect.get(target, property, target);
    return (query: string, ...bindings: SqlStorageValue[]) => {
      const cursor = target.exec(query, ...bindings);
      rows += cursor.rowsWritten;
      return cursor;
    };
  } });
  return { sql, writes: () => rows };
}

describe("durable diagnostic write budget", () => {
  it("checkpoints unchanged ticks once a minute while health reports the actual latest tick", async () => {
    await runInDurableObject(env.WATCHER.getByName("tick-budget"), (_instance, state) => {
      initializeSchema(state.storage.sql);
      const meter = measured(state.storage.sql);
      const runtime = new SQLiteRuntimeStore(meter.sql);
      runtime.recordTick(empty, at);
      expect(meter.writes()).toBe(2);
      runtime.recordTick(empty, at + 20_000);
      runtime.recordTick(empty, at + 59_999);
      expect(meter.writes()).toBe(2);
      expect(runtime.health().lastTickAt).toBe(new Date(at + 59_999).toISOString());
      const recreated = new SQLiteRuntimeStore(meter.sql);
      expect(recreated.health().lastTickAt).toBe(new Date(at).toISOString());
      recreated.recordTick(empty, at + 60_000);
      expect(meter.writes()).toBe(3);
      expect(new SQLiteRuntimeStore(meter.sql).health().lastTickAt).toBe(new Date(at + 60_000).toISOString());
    });
  });

  it("persists changed results immediately and protects the report from caller mutation", async () => {
    await runInDurableObject(env.WATCHER.getByName("changed-tick-budget"), (_instance, state) => {
      initializeSchema(state.storage.sql);
      const meter = measured(state.storage.sql);
      const runtime = new SQLiteRuntimeStore(meter.sql);
      runtime.recordTick(empty, at);
      const changed = { ...empty, tripsClaimed: 1, providerFailures: 1 };
      runtime.recordTick(changed, at + 1_000);
      expect(meter.writes()).toBe(3);
      changed.providerFailures = 99;
      expect(new SQLiteRuntimeStore(meter.sql).health().lastTick?.providerFailures).toBe(1);
      const result = runtime.health();
      result.lastTick!.providerFailures = 100;
      expect(runtime.health().lastTick?.providerFailures).toBe(1);
    });
  });

  it("reads legacy health until its next successful checkpoint", async () => {
    await runInDurableObject(env.WATCHER.getByName("legacy-tick-budget"), (_instance, state) => {
      initializeSchema(state.storage.sql);
      state.storage.sql.exec("INSERT INTO runtime_state (key,value,updated_at) VALUES (?,?,?)", "last_tick_at", new Date(at).toISOString(), at);
      state.storage.sql.exec("INSERT INTO runtime_state (key,value,updated_at) VALUES (?,?,?)", "last_tick", JSON.stringify(empty), at);
      const runtime = new SQLiteRuntimeStore(state.storage.sql);
      expect(runtime.health()).toMatchObject({ lastTickAt: new Date(at).toISOString(), lastTick: empty });
      runtime.recordTick({ ...empty, pushesClaimed: 1, pushesDelivered: 1 }, at + 1_000);
      expect(new SQLiteRuntimeStore(state.storage.sql).health().lastTick?.pushesDelivered).toBe(1);
    });
  });

  it("does not report a tick whose required checkpoint failed", async () => {
    await runInDurableObject(env.WATCHER.getByName("failed-tick-budget"), (_instance, state) => {
      initializeSchema(state.storage.sql);
      let fail = false;
      const unreliable = new Proxy(state.storage.sql, { get(target, property) {
        if (property !== "exec") return Reflect.get(target, property, target);
        return (query: string, ...bindings: SqlStorageValue[]) => {
          if (fail && query.startsWith("INSERT INTO runtime_state")) throw new Error("quota fixture");
          return target.exec(query, ...bindings);
        };
      } });
      const runtime = new SQLiteRuntimeStore(unreliable);
      runtime.recordTick(empty, at);
      fail = true;
      expect(() => runtime.recordTick({ ...empty, pushFailures: 1 }, at + 1_000)).toThrow("quota fixture");
      expect(runtime.health()).toMatchObject({ lastTickAt: new Date(at).toISOString(), lastTick: empty });
    });
  });
});

function platformSnapshot(): TripSnapshot {
  return {
    id: "eu:transitous:ice-budget", source: "transitous", nativeId: "ice-budget", serviceDate: "2026-11-17",
    operatorName: "DB Fernverkehr AG", product: "ICE", headsign: "Berlin", fetchedAt: new Date(at).toISOString(),
    stops: [{ stationId: "de:berlin", stationName: "Berlin Hbf", countryCode: "DE", latitude: 52.525, longitude: 13.369,
      sequence: 1, scheduledArrival: new Date(at + 60_000).toISOString(), scheduledDeparture: null,
      expectedArrival: null, expectedDeparture: null, plannedPlatform: "8", expectedPlatform: "11",
      platformSource: "DB Timetables", platformObservedAt: new Date(at).toISOString(), cancelled: false, passed: false }],
    alertIds: [],
  };
}

describe("platform observation write budget", () => {
  it("deduplicates cached receipts without dropping fresh timestamps or confirmed passage", async () => {
    await runInDurableObject(env.WATCHER.getByName("observation-budget"), (_instance, state) => {
      initializeSchema(state.storage.sql);
      const meter = measured(state.storage.sql);
      const store = new SQLitePlatformObservationStore(meter.sql);
      const snapshot = platformSnapshot();
      store.insert(store.project(snapshot, "snapshot"));
      const initialWrites = meter.writes();
      expect(initialWrites).toBeGreaterThan(0);
      for (let n = 0; n < 20; n++) store.insert(store.project(snapshot, "snapshot"));
      expect(meter.writes()).toBe(initialWrites);
      const row = () => state.storage.sql.exec("SELECT sample_count, passed, snapshot_fetched_at, collection_trigger FROM platform_observations").one();
      expect(row().sample_count).toBe(1);
      const later = { ...snapshot, fetchedAt: new Date(at + 20_000).toISOString() };
      store.insert(store.project(later, "watcher"));
      expect(row()).toMatchObject({ sample_count: 2, snapshot_fetched_at: at + 20_000, collection_trigger: "watcher" });
      const passed = { ...later, stops: [{ ...later.stops[0]!, passed: true }] };
      store.insert(store.project(passed, "watcher"));
      expect(row()).toMatchObject({ sample_count: 3, passed: 1 });
      const finalWrites = meter.writes();
      store.insert(store.project(passed, "watcher"));
      expect(meter.writes()).toBe(finalWrites);
    });
  });
});
