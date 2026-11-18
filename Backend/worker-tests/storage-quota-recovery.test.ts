import { createExecutionContext, env, runInDurableObject } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import worker from "../src/cloudflare/index.js";
import { TrainTrackerWatcher } from "../src/cloudflare/watcher-object.js";
import { createWatcherServices } from "../src/cloudflare/watcher-services.js";
import { initializeSchema } from "../src/cloudflare/schema.js";
import { createSchemaIfMissing } from "../src/cloudflare/schema-initialization.js";
import { SQLiteWatcherRepository } from "../src/cloudflare/sqlite-repository.js";
import { ProviderRegistry } from "../src/providers/provider.js";
import { MainlineJourneyProvider } from "../src/providers/mainline-journeys.js";
import { criteria, option, paris, reference } from "../tests/helpers/journey-search-service-fixtures.js";
import type { WorkerEnv } from "../src/cloudflare/env.js";
import type { TripSnapshot } from "../src/domain/snapshot.js";

const quotaMessage = "Exceeded allowed rows written in Durable Objects free tier.";
const freshSnapshot: TripSnapshot = {
  id: "us:amtraker:171", source: "amtraker", nativeId: "171", serviceDate: "2026-11-17",
  operatorName: "Amtrak", product: "171", headsign: "Washington", fetchedAt: "2026-11-17T15:00:00Z",
  stops: [], alertIds: [],
};

/** Reproduce the production gate: reads work; every attempted write throws. */
function exhaustWrites(sql: SqlStorage, blockEveryQuery = false) {
  const exec = sql.exec.bind(sql);
  const rejected: string[] = [];
  const spy = vi.spyOn(sql, "exec").mockImplementation((query, ...bindings) => {
    if (blockEveryQuery || !/^\s*(?:SELECT\b|WITH\b)/iu.test(query)) {
      rejected.push(query);
      throw new Error(quotaMessage);
    }
    return exec(query, ...bindings);
  });
  return { rejected, restore: () => spy.mockRestore() };
}

function localEnv(watcher: TrainTrackerWatcher): WorkerEnv {
  return { ...env, WATCHER: { getByName: () => watcher } } as unknown as WorkerEnv;
}

afterEach(() => vi.restoreAllMocks());

describe("read availability while Durable Object writes are exhausted", () => {
  it("constructs every watcher service without any SQL access", async () => {
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), async (_instance, state) => {
      const gate = exhaustWrites(state.storage.sql, true);
      try {
        expect(() => createWatcherServices(state, env)).not.toThrow();
        expect(gate.rejected).toEqual([]);
      } finally { gate.restore(); }
    });
  });

  it("serves native station search, caches results, and still enforces its rate limit", async () => {
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), async (_instance, state) => {
      const external = vi.spyOn(globalThis, "fetch").mockResolvedValue(Response.json({
        NYP: { code: "NYP", name: "New York Penn", city: "New York", state: "NY", lat: 40.75, lon: -73.99 },
      }));
      const gate = exhaustWrites(state.storage.sql, true);
      try {
        const watcher = new TrainTrackerWatcher(state, env);
        const read = (client: string) => worker.fetch(new Request(
          "https://api.test/v1/stations/search?scope=us&query=New%20York%20Penn",
          { headers: { "CF-Connecting-IP": client } },
        ) as unknown as Parameters<typeof worker.fetch>[0], localEnv(watcher), createExecutionContext());
        for (let index = 0; index < 30; index += 1) {
          const response = await read("198.51.100.181");
          expect(response.status).toBe(200);
          expect(await response.json()).toMatchObject([{ id: "us:amtraker:NYP", name: "New York Penn" }]);
        }
        const limited = await read("198.51.100.181");
        expect(limited.status).toBe(429);
        expect(await limited.json()).toEqual({ error: "rate_limited" });
        expect((await read("198.51.100.182")).status).toBe(200);
        expect(external).toHaveBeenCalledTimes(1);
        expect(gate.rejected).toEqual([]);
      } finally { gate.restore(); }
    });
  });

  it("returns the provider snapshot when optional platform writes hit the quota", async () => {
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), async (_instance, state) => {
      vi.spyOn(ProviderRegistry.prototype, "fetchTrip").mockResolvedValue(freshSnapshot);
      vi.spyOn(SQLiteWatcherRepository.prototype, "recordPlatformObservations").mockImplementation(() => {
        state.storage.sql.exec("INSERT INTO runtime_state (key, value, updated_at) VALUES ('probe', '1', 0)");
        return 1;
      });
      const forecast = vi.spyOn(SQLiteWatcherRepository.prototype, "forecastPlatformSnapshot");
      const gate = exhaustWrites(state.storage.sql);
      try {
        const watcher = new TrainTrackerWatcher(state, env);
        expect(await watcher.snapshot(freshSnapshot, "test-client")).toEqual(freshSnapshot);
        expect(await watcher.snapshot(freshSnapshot, "test-client")).toEqual(freshSnapshot);
        expect(forecast).not.toHaveBeenCalled();
        expect(gate.rejected).toHaveLength(1);
      } finally { gate.restore(); }
    });
  });

  it("does not hide unrelated platform persistence errors", async () => {
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), async (_instance, state) => {
      vi.spyOn(ProviderRegistry.prototype, "fetchTrip").mockResolvedValue(freshSnapshot);
      vi.spyOn(SQLiteWatcherRepository.prototype, "recordPlatformObservations").mockImplementation(() => {
        throw new Error("unexpected schema defect");
      });
      await expect(new TrainTrackerWatcher(state, env).snapshot(freshSnapshot, "test-client"))
        .rejects.toThrow("unexpected schema defect");
    });
  });

  it("preserves required writes and reports unavailable instead of successful mutation", async () => {
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), async (_instance, state) => {
      const gate = exhaustWrites(state.storage.sql);
      try {
        const watcher = new TrainTrackerWatcher(state, env);
        const response = await worker.fetch(new Request("https://api.test/v1/devices", {
          method: "POST", headers: { "content-type": "application/json", authorization: `Device ${"d".repeat(43)}` },
          body: JSON.stringify({ installationId: "ba141c63-e992-48ed-8c46-86cb6d42586a", token: "a".repeat(64),
            environment: "sandbox", platform: "ios" }),
        }) as unknown as Parameters<typeof worker.fetch>[0], localEnv(watcher), createExecutionContext());
        expect(response.status).toBe(503);
        expect(await response.json()).toEqual({ error: "service_unavailable" });
        expect(response.headers.get("cache-control")).toBe("no-store");
        expect(gate.rejected.length).toBeGreaterThan(0);
      } finally { gate.restore(); }
      initializeSchema(state.storage.sql);
      expect(state.storage.sql.exec("SELECT installation_id FROM devices").toArray()).toEqual([]);
    });
  });

  it("keeps public international discovery available when stored GTFS indexes cannot be read", async () => {
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), async (_instance, state) => {
      vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
        const url = new URL(typeof input === "string" || input instanceof URL ? input : input.url);
        if (url.origin !== "https://api.transitous.org") throw new Error("Unexpected provider");
        return Response.json([{
          type: "STOP", id: "de-test-berlin-hbf", name: "Berlin Hbf", lat: 52.52, lon: 13.37,
          country: "DE", modes: ["LONG_DISTANCE"],
        }]);
      });
      const unavailableKV = vi.spyOn(state.storage, "transaction").mockRejectedValue(new Error(quotaMessage));
      const gate = exhaustWrites(state.storage.sql, true);
      try {
        const response = await worker.fetch(new Request(
          "https://api.test/v1/stations/search?scope=international&query=Berlin%20Hbf",
        ) as unknown as Parameters<typeof worker.fetch>[0], localEnv(new TrainTrackerWatcher(state, env)), createExecutionContext());
        expect(response.status).toBe(200);
        expect(await response.json()).toContainEqual(expect.objectContaining({ name: "Berlin Hbf", countryCode: "DE" }));
        expect(gate.rejected).toEqual([]);
      } finally { gate.restore(); unavailableKV.mockRestore(); }
    });
  });

  it("keeps journey matching, signed resolution and journey limits without any SQL", async () => {
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), async (_instance, state) => {
      const tripReference = reference("transitous", "de-mainline-probe");
      const matched = option("quota-recovery", [{ segmentId: "segment-1", reference: tripReference }]);
      vi.spyOn(MainlineJourneyProvider.prototype, "searchPlaces").mockResolvedValue([paris]);
      vi.spyOn(MainlineJourneyProvider.prototype, "searchJourneys").mockResolvedValue({
        options: [matched], previousProviderCursor: null, nextProviderCursor: null, attributions: ["Transitous"],
      });
      vi.spyOn(ProviderRegistry.prototype, "fetchTrip").mockResolvedValue({ ...freshSnapshot, ...tripReference });
      const gate = exhaustWrites(state.storage.sql, true);
      const unavailableKV = vi.spyOn(state.storage, "transaction").mockRejectedValue(new Error(quotaMessage));
      try {
        const watcher = new TrainTrackerWatcher(state, env);
        expect(await watcher.searchPlaces("Paris Nord", 5, "quota-place")).toEqual([paris]);
        const page = await watcher.searchJourneys(criteria(), "quota-journey");
        expect(page.options).toHaveLength(1);
        expect(page.options[0]!.trackingToken).not.toBe(matched.trackingToken);
        const resolved = await watcher.resolveJourneyPlan([page.options[0]!.trackingToken], "quota-resolve");
        expect(resolved.directions[0]!.segments[0]!.trip?.id).toBe(tripReference.id);
        for (let index = 1; index < 12; index++) await watcher.searchJourneys(criteria(), "quota-journey");
        await expect(watcher.searchJourneys(criteria(), "quota-journey")).rejects.toMatchObject({ name: "JourneyRateLimitError" });
        expect(gate.rejected).toEqual([]);
      } finally { gate.restore(); unavailableKV.mockRestore(); }
    });
  });

  it("retries schema initialization on the same service after storage recovers", async () => {
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), async (_instance, state) => {
      const services = createWatcherServices(state, env);
      const gate = exhaustWrites(state.storage.sql, true);
      try {
        expect(() => services.repository.health()).toThrow(quotaMessage);
        expect(() => services.repository.health()).toThrow(quotaMessage);
        expect(gate.rejected).toHaveLength(2);
      } finally { gate.restore(); }
      const decision = services.repository.registerDevice({
        installationId: "ca141c63-e992-48ed-8c46-86cb6d42586a", token: "b".repeat(64), environment: "sandbox", platform: "ios",
      }, { credentialHash: "a".repeat(64), clientKey: "recovery-client" });
      expect(decision).toEqual({ allowed: true });
      expect(state.storage.sql.exec<{ foreign_keys: number }>("SELECT foreign_keys FROM pragma_foreign_keys").one().foreign_keys).toBe(1);
      expect(state.storage.sql.exec("SELECT installation_id FROM devices").toArray()).toHaveLength(1);
      expect(() => state.storage.sql.exec("INSERT INTO app_profiles (user_id, created_at, updated_at) VALUES ('missing-parent', 0, 0)"))
        .toThrow(/FOREIGN KEY/iu);
    });
  });
});

describe("schema migration integrity", () => {
  it("still creates a missing index and refuses to pretend an incomplete schema is ready", async () => {
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), async (_instance, state) => {
      initializeSchema(state.storage.sql);
      state.storage.sql.exec("DROP INDEX tracked_trips_due_idx");
      const gate = exhaustWrites(state.storage.sql);
      try { expect(() => initializeSchema(state.storage.sql)).toThrow(quotaMessage); }
      finally { gate.restore(); }
      initializeSchema(state.storage.sql);
      expect(state.storage.sql.exec("SELECT name FROM sqlite_master WHERE name = 'tracked_trips_due_idx'").toArray())
        .toEqual([{ name: "tracked_trips_due_idx" }]);
    });
  });

  it("creates new schemas once and keeps existing table data intact", async () => {
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), async (_instance, state) => {
      const definition = "CREATE TABLE IF NOT EXISTS recovery_probe (value TEXT); CREATE INDEX IF NOT EXISTS recovery_probe_idx ON recovery_probe(value);";
      expect(createSchemaIfMissing(state.storage.sql, definition)).toBe(true);
      state.storage.sql.exec("INSERT INTO recovery_probe VALUES ('preserved')");
      const gate = exhaustWrites(state.storage.sql);
      try { expect(createSchemaIfMissing(state.storage.sql, definition)).toBe(false); }
      finally { gate.restore(); }
      expect(state.storage.sql.exec("SELECT value FROM recovery_probe").toArray()).toEqual([{ value: "preserved" }]);
    });
  });
});
