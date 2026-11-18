import { env, runDurableObjectAlarm, SELF } from "cloudflare:test";
import { runInInitializedWatcher as runInDurableObject } from "./initialized-watcher.js";
import { describe, expect, it, vi } from "vitest";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import type { MaterialEvent } from "../src/domain/events.js";
import { SQLiteWatcherRepository } from "../src/cloudflare/sqlite-repository.js";

const dayMilliseconds = 24 * 60 * 60_000;
const preferences = { delayThresholdMinutes: 5, platformChanges: true, cancellations: true, disruptions: true };

function isoDate(value: number): string {
  return new Date(value).toISOString().slice(0, 10);
}

function context(name: string) {
  return { credentialHash: name.padEnd(64, "0").slice(0, 64), clientKey: `client-${name}` };
}

function device(installationId: string, tokenDigit: string) {
  return { installationId, token: tokenDigit.repeat(64), environment: "sandbox" as const, platform: "ios" as const };
}

function subscription(installationId: string, overrides: {
  id?: string; nativeId?: string; serviceDate?: string; watchFrom?: number;
} = {}) {
  const now = Date.now();
  return {
    installationId,
    trip: {
      id: overrides.id ?? "us:amtraker:171-hardening",
      source: "amtraker" as const,
      nativeId: overrides.nativeId ?? "171-hardening",
      serviceDate: overrides.serviceDate ?? isoDate(now),
    },
    boardingStationId: "us:amtraker:NYP",
    alightingStationId: "us:amtraker:WAS",
    watchFrom: new Date(overrides.watchFrom ?? now - 60_000).toISOString(),
    preferences,
  };
}

function snapshot(id: string, nativeId: string, serviceDate: string): TripSnapshot {
  return {
    id, source: "amtraker", nativeId, serviceDate, operatorName: "Amtrak", product: "171",
    headsign: "Washington", fetchedAt: new Date().toISOString(), alertIds: [], stops: [{
      stationId: "us:amtraker:WAS", stationName: "Washington", countryCode: "US", latitude: null, longitude: null,
      sequence: 1, scheduledArrival: new Date(Date.now() + 3_600_000).toISOString(), scheduledDeparture: null,
      expectedArrival: null, expectedDeparture: null, plannedPlatform: "4", expectedPlatform: null,
      platformSource: null, platformObservedAt: null, cancelled: false, passed: false,
    }],
  };
}

function event(tripId: string, fingerprint: string): MaterialEvent {
  return {
    kind: "delay-threshold", tripId, stopId: null, title: "Delayed", body: "Now 10 minutes late.",
    oldValue: null, newValue: "10", fingerprint,
  };
}

describe("shared tracked trips", () => {
  it("does not let one installation repoint a trip other installations watch", async () => {
    await runInDurableObject(env.WATCHER.getByName("trip-identity"), async (_instance, state) => {
      const repository = new SQLiteWatcherRepository(state.storage);
      const victim = "aa000000-0000-4000-8000-000000000001";
      const attacker = "aa000000-0000-4000-8000-000000000002";
      expect(repository.registerDevice(device(victim, "a"), context("victim"))).toEqual({ allowed: true });
      expect(repository.registerDevice(device(attacker, "b"), context("attacker"))).toEqual({ allowed: true });
      const original = subscription(victim);
      expect(repository.subscribe(original, context("victim"))).toEqual({ allowed: true });
      const watchId = `${original.trip.id}@${original.trip.serviceDate}`;
      await repository.recordSuccess(watchId, snapshot(watchId, original.trip.nativeId, original.trip.serviceDate), 30, []);

      expect(repository.subscribe(subscription(attacker, { nativeId: "other-train" }), context("attacker")))
        .toEqual({ allowed: false, reason: "trip_conflict" });
      const row = state.storage.sql.exec<{ native_id: string; latest_snapshot: string | null }>(
        "SELECT native_id, latest_snapshot FROM tracked_trips WHERE id = ?", watchId,
      ).one();
      expect(row.native_id).toBe(original.trip.nativeId);
      expect(row.latest_snapshot).not.toBeNull();

      // Subscribing to the same train is still shared normally.
      expect(repository.subscribe(subscription(attacker), context("attacker"))).toEqual({ allowed: true });
    });
  });

  it("clears the stored snapshot when the sole watcher corrects the train identity", async () => {
    await runInDurableObject(env.WATCHER.getByName("trip-identity-sole"), async (_instance, state) => {
      const repository = new SQLiteWatcherRepository(state.storage);
      const owner = "ab000000-0000-4000-8000-000000000001";
      expect(repository.registerDevice(device(owner, "c"), context("owner"))).toEqual({ allowed: true });
      const original = subscription(owner);
      expect(repository.subscribe(original, context("owner"))).toEqual({ allowed: true });
      const watchId = `${original.trip.id}@${original.trip.serviceDate}`;
      await repository.recordSuccess(watchId, snapshot(watchId, original.trip.nativeId, original.trip.serviceDate), 30, []);

      expect(repository.subscribe(subscription(owner, { nativeId: "corrected" }), context("owner"))).toEqual({ allowed: true });
      const row = state.storage.sql.exec<{ native_id: string; latest_snapshot: string | null }>(
        "SELECT native_id, latest_snapshot FROM tracked_trips WHERE id = ?", watchId,
      ).one();
      expect(row).toEqual({ native_id: "corrected", latest_snapshot: null });
    });
  });
});

describe("watch retirement and scheduling", () => {
  it("retires a watch whose fetch always fails once its service date is past, freeing quota", async () => {
    await runInDurableObject(env.WATCHER.getByName("failing-watch"), async (_instance, state) => {
      const repository = new SQLiteWatcherRepository(state.storage);
      const now = Date.now();
      const installationId = "ac000000-0000-4000-8000-000000000001";
      expect(repository.registerDevice(device(installationId, "d"), context("failing"))).toEqual({ allowed: true });
      const stale = subscription(installationId, { serviceDate: isoDate(now - 3 * dayMilliseconds) });
      expect(repository.subscribe(stale, context("failing"))).toEqual({ allowed: true });
      const watchId = `${stale.trip.id}@${stale.trip.serviceDate}`;
      expect(repository.hasWork(now)).toBe(true);

      await repository.recordFailure(watchId, new Error("provider down"), now);
      expect(repository.health().activeSubscriptions).toBe(0);
      expect(repository.hasWork(now)).toBe(false);
    });
  });

  it("recovers a multi-day watch after a transient failure while its saved arrival is future", async () => {
    await runInDurableObject(env.WATCHER.getByName("multi-day-watch-recovery"), async (_instance, state) => {
      const repository = new SQLiteWatcherRepository(state.storage);
      const now = Date.now();
      const installationId = "ac000000-0000-4000-8000-000000000002";
      expect(repository.registerDevice(device(installationId, "d"), context("multi-day"))).toEqual({ allowed: true });
      const input = subscription(installationId, { serviceDate: isoDate(now - 3 * dayMilliseconds) });
      expect(repository.subscribe(input, context("multi-day"))).toEqual({ allowed: true });
      const watchId = `${input.trip.id}@${input.trip.serviceDate}`;
      const saved = snapshot(input.trip.id, input.trip.nativeId, input.trip.serviceDate);
      await repository.recordSuccess(watchId, saved, 30, []);

      await repository.recordFailure(watchId, new Error("Amtraker returned 429"), now);
      expect(repository.health().activeSubscriptions).toBe(1);
      expect(repository.maintain(now).retiredSubscriptions).toBe(0);
      // Backoff can elapse and the very same subscription can receive the next update.
      state.storage.sql.exec("UPDATE tracked_trips SET next_poll_at = ? WHERE id = ?", now - 1, watchId);
      expect((await repository.claimDueTrips()).map((trip) => trip.id)).toContain(watchId);
      await repository.recordSuccess(watchId, saved, 30, []);
      expect(repository.health().activeSubscriptions).toBe(1);
      expect(state.storage.sql.exec<{ consecutive_failures: number }>(
        "SELECT consecutive_failures FROM tracked_trips WHERE id = ?", watchId,
      ).one().consecutive_failures).toBe(0);

      // Retention is still bounded when the arrival and recovery grace really pass.
      const afterRecovery = Date.parse(saved.stops[0]!.scheduledArrival!) + 2 * 60 * 60_000 + 1;
      await repository.recordFailure(watchId, new Error("provider unavailable"), afterRecovery);
      expect(repository.health().activeSubscriptions).toBe(0);
    });
  });

  it("retains a delayed multi-day watch with real GPS beyond its last timetable estimate", async () => {
    await runInDurableObject(env.WATCHER.getByName("multi-day-watch-position"), async (_instance, state) => {
      const repository = new SQLiteWatcherRepository(state.storage);
      const now = Date.now();
      const installationId = "ac000000-0000-4000-8000-000000000003";
      expect(repository.registerDevice(device(installationId, "e"), context("position-recovery"))).toEqual({ allowed: true });
      const input = subscription(installationId, { serviceDate: isoDate(now - 3 * dayMilliseconds) });
      expect(repository.subscribe(input, context("position-recovery"))).toEqual({ allowed: true });
      const watchId = `${input.trip.id}@${input.trip.serviceDate}`;
      const base = snapshot(input.trip.id, input.trip.nativeId, input.trip.serviceDate);
      const delayed: TripSnapshot = { ...base,
        stops: base.stops.map((stop) => ({ ...stop, scheduledArrival: new Date(now - 4 * 60 * 60_000).toISOString() })),
        positions: [{ latitude: 39.5, longitude: -76.5, heading: null, source: "real", confidence: 1,
          asOf: new Date(now - 60_000).toISOString(), provider: "Amtraker" }],
      };
      await repository.recordSuccess(watchId, delayed, 30, []);
      expect(repository.health().activeSubscriptions).toBe(1);
      await repository.recordFailure(watchId, new Error("request timed out"), now);
      expect(repository.maintain(now).retiredSubscriptions).toBe(0);
      expect(repository.health().activeSubscriptions).toBe(1);

      // A fixed provider timestamp is never renewed merely by another fetch.
      const expired = now + 2 * 60 * 60_000;
      await repository.recordFailure(watchId, new Error("request timed out"), expired);
      expect(repository.health().activeSubscriptions).toBe(0);
    });
  });

  it("sweeps stale never-polled watches and keeps current ones", async () => {
    await runInDurableObject(env.WATCHER.getByName("stale-sweep"), async (_instance, state) => {
      const repository = new SQLiteWatcherRepository(state.storage);
      const now = Date.now();
      const installationId = "ad000000-0000-4000-8000-000000000001";
      expect(repository.registerDevice(device(installationId, "e"), context("sweep"))).toEqual({ allowed: true });
      expect(repository.subscribe(subscription(installationId, {
        id: "us:amtraker:old", nativeId: "old", serviceDate: isoDate(now - 5 * dayMilliseconds),
      }), context("sweep"))).toEqual({ allowed: true });
      expect(repository.subscribe(subscription(installationId, { id: "us:amtraker:today", nativeId: "today" }), context("sweep")))
        .toEqual({ allowed: true });

      expect(repository.maintain(now).retiredSubscriptions).toBeGreaterThan(0);
      expect(state.storage.sql.exec<{ trip_id: string }>(
        "SELECT trip_id FROM subscriptions WHERE active = 1",
      ).toArray().map((row) => row.trip_id)).toEqual([`us:amtraker:today@${isoDate(now)}`]);
    });
  });

  it("counts only started watches as work and parks the alarm until the next one starts", async () => {
    const watcher = env.WATCHER.getByName("future-watch");
    const now = Date.now();
    const startsAt = now + 30 * 60_000;
    await runInDurableObject(watcher, async (_instance, state) => {
      const repository = new SQLiteWatcherRepository(state.storage);
      const installationId = "ae000000-0000-4000-8000-000000000001";
      expect(repository.registerDevice(device(installationId, "f"), context("future"))).toEqual({ allowed: true });
      expect(repository.subscribe(subscription(installationId, { watchFrom: startsAt }), context("future")))
        .toEqual({ allowed: true });
      expect(repository.hasWork(now)).toBe(false);
      expect(repository.nextWatchStart(now)).toBe(startsAt);
      await state.storage.setAlarm(now + 1_000);
    });
    expect(await runDurableObjectAlarm(watcher)).toBe(true);
    const health = await watcher.health();
    expect(Date.parse(health.alarmScheduledAt!)).toBe(startsAt);
  });
});

describe("push outbox", () => {
  it("fails every undelivered message for a retired installation and caps retries", async () => {
    await runInDurableObject(env.WATCHER.getByName("outbox-retire"), async (_instance, state) => {
      const repository = new SQLiteWatcherRepository(state.storage);
      const installationId = "af000000-0000-4000-8000-000000000001";
      const other = "af000000-0000-4000-8000-000000000002";
      expect(repository.registerDevice(device(installationId, "1"), context("retire"))).toEqual({ allowed: true });
      expect(repository.registerDevice(device(other, "2"), context("other"))).toEqual({ allowed: true });
      const input = subscription(installationId);
      expect(repository.subscribe(input, context("retire"))).toEqual({ allowed: true });
      expect(repository.subscribe(subscription(other), context("other"))).toEqual({ allowed: true });
      const watchId = `${input.trip.id}@${input.trip.serviceDate}`;
      await repository.recordSuccess(watchId, snapshot(watchId, input.trip.nativeId, input.trip.serviceDate), 30, [
        { installationId, event: event(watchId, "1".repeat(64)) },
        { installationId, event: event(watchId, "2".repeat(64)) },
        { installationId, event: event(watchId, "3".repeat(64)) },
        { installationId: other, event: event(watchId, "1".repeat(64)) },
      ]);

      const claimed = await repository.claimOutbox(1);
      expect(claimed[0]?.createdAt).toBeGreaterThan(0);
      await repository.retireDevice("1".repeat(64));
      await repository.markDeliveryFailed(claimed[0]!.id, new Error("Unregistered"), true);

      const statuses = state.storage.sql.exec<{ installation_id: string; status: string }>(
        "SELECT installation_id, status FROM notification_outbox ORDER BY id",
      ).toArray();
      expect(statuses.filter((row) => row.installation_id === installationId).map((row) => row.status))
        .toEqual(["failed", "failed", "failed"]);
      expect(statuses.filter((row) => row.installation_id === other).map((row) => row.status)).toEqual(["pending"]);

      // Re-registering the same installation does not replay its backlog.
      expect(repository.registerDevice(device(installationId, "1"), context("retire"))).toEqual({ allowed: true });
      expect((await repository.claimOutbox(10)).map((message) => message.token)).toEqual(["2".repeat(64)]);

      const [remaining] = state.storage.sql.exec<{ id: number }>(
        "SELECT id FROM notification_outbox WHERE installation_id = ?", other,
      ).toArray();
      state.storage.sql.exec("UPDATE notification_outbox SET attempts = 8 WHERE id = ?", remaining!.id);
      await repository.markDeliveryFailed(String(remaining!.id), new Error("APNs 503"), false);
      expect(state.storage.sql.exec<{ status: string }>(
        "SELECT status FROM notification_outbox WHERE id = ?", remaining!.id,
      ).one().status).toBe("failed");
    });
  });
});

describe("retention", () => {
  it("prunes old outbox, events, trips, inactive devices, and expired auth rows in bounded batches", async () => {
    await runInDurableObject(env.WATCHER.getByName("retention"), async (_instance, state) => {
      const repository = new SQLiteWatcherRepository(state.storage);
      const sql = state.storage.sql;
      const now = Date.now();
      const old = now - 40 * dayMilliseconds;
      const keep = "b0000000-0000-4000-8000-000000000001";
      const gone = "b0000000-0000-4000-8000-000000000002";
      sql.exec(`INSERT INTO devices (installation_id, apns_token, credential_hash, environment, platform, active, created_at, updated_at)
        VALUES (?, ?, NULL, 'sandbox', 'ios', 1, ?, ?), (?, ?, NULL, 'sandbox', 'ios', 0, ?, ?)`,
      keep, "7".repeat(64), old, old, gone, "8".repeat(64), old, old);
      const oldDate = isoDate(now - 10 * dayMilliseconds);
      const today = isoDate(now);
      sql.exec(`INSERT INTO tracked_trips (id, client_trip_id, source, native_id, service_date, next_poll_at, created_at, updated_at)
        VALUES ('old@x', 'old', 'amtraker', 'old', ?, 0, ?, ?), ('new@x', 'new', 'amtraker', 'new', ?, 0, ?, ?)`,
      oldDate, old, old, today, now, now);
      sql.exec(`INSERT INTO subscriptions (installation_id, trip_id, boarding_station_id, alighting_station_id, watch_from, preferences, active, created_at, updated_at)
        VALUES (?, 'old@x', 'a', 'b', 0, '{}', 0, ?, ?), (?, 'new@x', 'a', 'b', 0, '{}', 1, ?, ?)`,
      keep, old, old, keep, now, now);
      sql.exec(`INSERT INTO notification_events (fingerprint, trip_id, kind, payload, created_at)
        VALUES ('e-old', 'new@x', 'delay-threshold', '{}', ?), ('e-new', 'new@x', 'delay-threshold', '{}', ?),
               ('e-recent-delivered', 'new@x', 'delay-threshold', '{}', ?)`,
      now - 20 * dayMilliseconds, now, now - 10 * dayMilliseconds);
      sql.exec(`INSERT INTO notification_outbox (event_fingerprint, installation_id, payload, status, attempts, next_attempt_at, created_at)
        VALUES ('e-recent-delivered', ?, '{}', 'delivered', 1, 0, ?), ('e-new', ?, '{}', 'pending', 0, 0, ?)`,
      keep, now - 10 * dayMilliseconds, keep, now);
      sql.exec("INSERT INTO gmail_users (id, created_at) VALUES ('user-1', ?)", old);
      sql.exec(`INSERT INTO app_sessions (token_hash, user_id, expires_at, created_at, last_used_at)
        VALUES ('expired', 'user-1', ?, ?, ?), ('live', 'user-1', ?, ?, ?)`, now - 1, old, old, now + dayMilliseconds, now, now);
      sql.exec(`INSERT INTO auth_exchange_codes (code_hash, user_id, transaction_id, app_challenge, expires_at)
        VALUES ('expired', 'user-1', 't', 'c', ?), ('live', 'user-1', 't', 'c', ?)`, now - 1, now + 60_000);
      sql.exec(`INSERT INTO gmail_sessions (token_hash, user_id, expires_at, created_at, last_used_at)
        VALUES ('gmail-expired', 'user-1', ?, ?, ?)`, now - 1, old, old);

      const report = repository.maintain(now);
      expect(report).toMatchObject({ prunedEvents: 1, prunedTrips: 1, prunedDevices: 1 });

      const ids = (query: string) => sql.exec<{ id: string }>(query).toArray().map((row) => row.id);
      expect(ids("SELECT id FROM tracked_trips")).toEqual(["new@x"]);
      expect(ids("SELECT installation_id AS id FROM devices")).toEqual([keep]);
      expect(ids("SELECT trip_id AS id FROM subscriptions")).toEqual(["new@x"]);
      expect(ids("SELECT fingerprint AS id FROM notification_events ORDER BY fingerprint"))
        .toEqual(["e-new", "e-recent-delivered"]);
      expect(ids("SELECT event_fingerprint AS id FROM notification_outbox")).toEqual(["e-new"]);
      expect(ids("SELECT token_hash AS id FROM app_sessions")).toEqual(["live"]);
      expect(ids("SELECT code_hash AS id FROM auth_exchange_codes")).toEqual(["live"]);
      // Gmail tables are out of scope for retention.
      expect(ids("SELECT token_hash AS id FROM gmail_sessions")).toEqual(["gmail-expired"]);
    });
  });

  it("limits each pass to the batch size", async () => {
    await runInDurableObject(env.WATCHER.getByName("retention-batch"), async (_instance, state) => {
      const repository = new SQLiteWatcherRepository(state.storage);
      const now = Date.now();
      state.storage.sql.exec("INSERT INTO gmail_users (id, created_at) VALUES ('user-1', 0)");
      for (let index = 0; index < 150; index += 1) {
        state.storage.sql.exec(
          "INSERT INTO app_sessions (token_hash, user_id, expires_at, created_at, last_used_at) VALUES (?, 'user-1', 0, 0, 0)",
          `expired-${index}`,
        );
      }
      repository.maintain(now);
      expect(state.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM app_sessions").one().count).toBe(50);
      repository.maintain(now);
      expect(state.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM app_sessions").one().count).toBe(0);
    });
  });
});

describe("public endpoints", () => {
  it("rate limits provider-backed reads per client network", async () => {
    const externalFetch = vi.spyOn(globalThis, "fetch").mockImplementation(async () => Response.json([]));
    const read = (address: string) => SELF.fetch(
      "https://example.test/v1/stations/search?scope=international&query=RateLimitedStation",
      { headers: { "CF-Connecting-IP": address } },
    );
    for (let index = 0; index < 30; index += 1) {
      expect((await read("198.51.100.90")).status).not.toBe(429);
    }
    const limited = await read("198.51.100.90");
    expect(limited.status).toBe(429);
    expect(Number(limited.headers.get("retry-after"))).toBeGreaterThan(0);
    expect(await limited.json()).toEqual({ error: "rate_limited" });
    expect((await read("198.51.100.91")).status).not.toBe(429);
    externalFetch.mockRestore();
  });

  it("returns 404 for a malformed share token instead of a server error", async () => {
    for (const path of ["/s/%E0%A4%A", "/v1/shares/%ZZ"]) {
      const response = await SELF.fetch(`https://example.test${path}`);
      expect(response.status, path).toBe(404);
    }
  });

  it("rejects oversized share bodies with 413", async () => {
    const response = await SELF.fetch("https://example.test/v1/shares", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ padding: "x".repeat(70 * 1_024) }),
    });
    expect(response.status).toBe(413);
    expect(await response.json()).toEqual({ error: "request_too_large" });
  });
});
