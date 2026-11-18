import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { makeDatabasePool, type DatabasePool } from "../src/db/database.js";
import { WatcherRepository } from "../src/db/repository.js";
import type { MaterialEvent } from "../src/domain/events.js";
import { defaultPushPreferences, type TripSnapshot } from "../src/domain/snapshot.js";

const integration = process.env.RUN_DATABASE_TESTS === "true" ? describe : describe.skip;

integration("WatcherRepository", () => {
  let pool: DatabasePool;
  let repository: WatcherRepository;

  beforeAll(() => {
    pool = makeDatabasePool(
      process.env.DATABASE_URL ?? "postgres://traintracker:traintracker@localhost:5432/traintracker",
      false,
    );
    repository = new WatcherRepository(pool);
  });

  afterAll(async () => {
    await pool.end();
  });

  it("commits a material event to the transactional outbox exactly once", async () => {
    const suffix = randomUUID();
    const installationId = randomUUID();
    const tripId = `us:amtraker:integration-${suffix}`;
    const watchId = `${tripId}@2026-07-20`;
    const fingerprint = `integration-${suffix}`;
    const token = suffix.replaceAll("-", "").repeat(2);

    const credentialHash = "c".repeat(64);
    await repository.registerDevice({ installationId, token, environment: "sandbox", platform: "ios" }, credentialHash);
    await repository.subscribe({
      installationId,
      trip: { id: tripId, source: "amtraker", nativeId: "171", serviceDate: "2026-07-20" },
      boardingStationId: "us:amtraker:NYP",
      alightingStationId: "us:amtraker:PHL",
      watchFrom: "2026-07-20T00:00:00.000Z",
      preferences: defaultPushPreferences,
    }, credentialHash);

    const snapshot: TripSnapshot = {
      id: watchId,
      source: "amtraker",
      nativeId: "171",
      serviceDate: "2026-07-20",
      operatorName: "Amtrak",
      product: "Northeast Regional 171",
      headsign: "Philadelphia",
      fetchedAt: new Date().toISOString(),
      alertIds: [],
      stops: [{
        stationId: "us:amtraker:NYP",
        stationName: "New York Penn",
        countryCode: "US",
        latitude: 40.7506,
        longitude: -73.9935,
        sequence: 1,
        scheduledArrival: null,
        scheduledDeparture: "2099-07-20T16:05:00.000Z",
        expectedArrival: null,
        expectedDeparture: "2099-07-20T16:05:00.000Z",
        plannedPlatform: "8",
        expectedPlatform: "9",
        platformSource: "Amtraker",
        platformObservedAt: null,
        cancelled: false,
        passed: false,
      }],
    };
    const event: MaterialEvent = {
      kind: "platform-change",
      tripId: watchId,
      stopId: "us:amtraker:NYP",
      title: "Platform changed",
      body: "Now platform 9.",
      oldValue: "8",
      newValue: "9",
      fingerprint,
    };

    await repository.recordSuccess(watchId, snapshot, 30, [{ installationId, event }, { installationId, event }]);
    const messages = await repository.claimOutbox(100);
    const matching = messages.filter((message) => message.payload.fingerprint === fingerprint);
    expect(matching).toHaveLength(1);
    expect(matching[0]).toMatchObject({ token, environment: "sandbox", platform: "ios" });

    await repository.markDeliveryFailed(matching[0]!.id, new Error("BadDeviceToken"), true);
    const reclaimed = await repository.claimOutbox(100);
    expect(reclaimed.some((message) => message.payload.fingerprint === fingerprint)).toBe(false);

    await pool.query("DELETE FROM devices WHERE installation_id = $1", [installationId]);
    await pool.query("DELETE FROM tracked_trips WHERE id = $1", [watchId]);
  });

  it("requires the device credential and never hands a token to another installation", async () => {
    const owner = randomUUID();
    const intruder = randomUUID();
    const token = randomUUID().replaceAll("-", "").repeat(2);
    const ownerCredential = "a".repeat(64);
    const intruderCredential = "b".repeat(64);
    const device = { installationId: owner, token, environment: "sandbox" as const, platform: "ios" as const };
    const trip = { id: `us:amtraker:credential-${owner}`, source: "amtraker" as const, nativeId: "171", serviceDate: "2026-07-20" };
    const subscription = {
      installationId: owner, trip, boardingStationId: "us:amtraker:NYP", alightingStationId: "us:amtraker:PHL",
      watchFrom: "2026-07-20T00:00:00.000Z", preferences: defaultPushPreferences,
    };

    expect(await repository.registerDevice(device, ownerCredential)).toBe("allowed");
    expect(await repository.registerDevice({ ...device, installationId: intruder }, intruderCredential)).toBe("token_conflict");
    expect(await repository.registerDevice({ ...device, token: token.replace(/^./u, "f") }, intruderCredential)).toBe("unauthorized");
    expect(await repository.subscribe(subscription, intruderCredential)).toBe("unauthorized");
    expect(await repository.subscribe(subscription, ownerCredential)).toBe("allowed");
    expect(await repository.unsubscribe(owner, trip.id, intruderCredential)).toBe("unauthorized");
    const stored = await pool.query<{ installation_id: string }>("SELECT installation_id FROM devices WHERE apns_token = $1", [token]);
    expect(stored.rows.map((row) => row.installation_id)).toEqual([owner]);

    expect(await repository.registerDevice({ ...device, installationId: intruder, token: token.replace(/^./u, "e") }, intruderCredential)).toBe("allowed");
    expect(await repository.subscribe({ ...subscription, installationId: intruder, trip: { ...trip, nativeId: "999" } }, intruderCredential))
      .toBe("trip_conflict");

    await pool.query("DELETE FROM devices WHERE installation_id = ANY($1)", [[owner, intruder]]);
    await pool.query("DELETE FROM tracked_trips WHERE client_trip_id = $1", [trip.id]);
  });

  it("upserts canonical platform observations without rider data", async () => {
    const nativeId = `ice-${randomUUID()}`;
    const snapshot: TripSnapshot = {
      id: `eu:transitous:${nativeId}`,
      source: "transitous",
      nativeId,
      serviceDate: "2026-07-21",
      operatorName: "DB Fernverkehr AG",
      product: "ICE 742",
      headsign: "Münster Hbf",
      fetchedAt: "2026-07-21T16:10:05.000Z",
      alertIds: [],
      stops: [{
        stationId: "eu:transitous:berlin-hbf",
        stationName: "Berlin Hbf",
        countryCode: "DE",
        latitude: 52.525,
        longitude: 13.369,
        sequence: 1,
        scheduledArrival: "2026-07-21T16:12:00.000Z",
        scheduledDeparture: "2026-07-21T16:16:00.000Z",
        expectedArrival: "2026-07-21T16:12:00.000Z",
        expectedDeparture: "2026-07-21T16:21:00.000Z",
        plannedPlatform: "8",
        expectedPlatform: "11",
        platformSource: "DB Timetables",
        platformObservedAt: "2026-07-21T16:10:00.000Z",
        cancelled: false,
        passed: false,
      }],
    };

    expect(await repository.recordPlatformObservations(snapshot, "snapshot")).toBe(1);
    expect(await repository.recordPlatformObservations({
      ...snapshot,
      fetchedAt: "2026-07-21T16:10:25.000Z",
    }, "watcher")).toBe(1);

    const result = await pool.query<{
      sample_count: number;
      source_license: string;
      payload: object;
    }>(
      `SELECT sample_count, source_license, payload
       FROM platform_observations
       WHERE native_trip_id = $1`,
      [nativeId],
    );
    expect(result.rows).toHaveLength(1);
    expect(result.rows[0]).toMatchObject({ sample_count: 2, source_license: "CC BY 4.0" });
    const payload = JSON.stringify(result.rows[0]?.payload);
    for (const forbidden of ["installationId", "accountId", "passenger", "ticket", "coach", "seat", "pushToken"]) {
      expect(payload).not.toContain(forbidden);
    }

    await pool.query("DELETE FROM platform_observations WHERE native_trip_id = $1", [nativeId]);
  });

  it("persists and finalizes an idempotent historical shadow forecast", async () => {
    const suffix = randomUUID();
    for (let index = 0; index < 30; index += 1) {
      const date = new Date(Date.UTC(2026, 0, index + 1, 12));
      const serviceDate = date.toISOString().slice(0, 10);
      const snapshot: TripSnapshot = {
        id: `eu:transitous:history-${suffix}-${index}`,
        source: "transitous",
        nativeId: `history-${suffix}-${index}`,
        serviceDate,
        operatorName: "DB Fernverkehr AG",
        product: "ICE 742",
        headsign: "Münster Hbf",
        fetchedAt: `${serviceDate}T12:06:00.000Z`,
        alertIds: [],
        stops: [{
          stationId: "eu:transitous:berlin-hbf",
          stationName: "Berlin Hbf",
          countryCode: "DE",
          latitude: 52.525,
          longitude: 13.369,
          sequence: 1,
          scheduledArrival: null,
          scheduledDeparture: `${serviceDate}T12:00:00.000Z`,
          expectedArrival: null,
          expectedDeparture: `${serviceDate}T12:00:00.000Z`,
          plannedPlatform: "8",
          expectedPlatform: index < 27 ? "8" : "9",
          platformSource: "DB Timetables",
          platformObservedAt: `${serviceDate}T12:05:00.000Z`,
          cancelled: false,
          passed: true,
        }],
      };
      expect(await repository.recordPlatformObservations(snapshot, "watcher")).toBe(1);
    }

    const current: TripSnapshot = {
      id: `eu:transitous:current-${suffix}`,
      source: "transitous",
      nativeId: `current-${suffix}`,
      serviceDate: "2026-08-01",
      operatorName: "DB Fernverkehr AG",
      product: "ICE 742",
      headsign: "Münster Hbf",
      fetchedAt: "2026-08-01T08:00:00.000Z",
      alertIds: [],
      stops: [{
        stationId: "eu:transitous:berlin-hbf",
        stationName: "Berlin Hbf",
        countryCode: "DE",
        latitude: 52.525,
        longitude: 13.369,
        sequence: 1,
        scheduledArrival: null,
        scheduledDeparture: "2026-08-01T12:00:00.000Z",
        expectedArrival: null,
        expectedDeparture: null,
        plannedPlatform: null,
        expectedPlatform: null,
        platformSource: null,
        platformObservedAt: null,
        cancelled: false,
        passed: false,
      }],
    };

    await repository.forecastPlatformSnapshot(current, "2026-08-01T08:00:00.000Z");
    await repository.forecastPlatformSnapshot(current, "2026-08-01T08:05:00.000Z");
    let result = await pool.query<{ forecasts: number; outcomes: number }>(
      `SELECT COUNT(*)::integer AS forecasts,
              COUNT(*) FILTER (WHERE scored_at IS NOT NULL)::integer AS outcomes
       FROM platform_shadow_forecasts WHERE event_id LIKE $1`,
      [`%current-${suffix}%`],
    );
    expect(result.rows[0]).toEqual({ forecasts: 1, outcomes: 0 });

    await repository.recordPlatformObservations({
      ...current,
      fetchedAt: "2026-08-01T12:06:00.000Z",
      stops: [{
        ...current.stops[0]!,
        expectedPlatform: "8",
        platformSource: "DB Timetables",
        platformObservedAt: "2026-08-01T12:05:00.000Z",
        passed: true,
      }],
    }, "watcher");
    result = await pool.query<{ forecasts: number; outcomes: number }>(
      `SELECT COUNT(*)::integer AS forecasts,
              COUNT(*) FILTER (WHERE scored_at IS NOT NULL)::integer AS outcomes
       FROM platform_shadow_forecasts WHERE event_id LIKE $1`,
      [`%current-${suffix}%`],
    );
    expect(result.rows[0]).toEqual({ forecasts: 1, outcomes: 1 });

    await pool.query("DELETE FROM platform_shadow_forecasts WHERE event_id LIKE $1", [`%${suffix}%`]);
    await pool.query("DELETE FROM platform_observations WHERE native_trip_id LIKE $1", [`%${suffix}%`]);
  });
});
