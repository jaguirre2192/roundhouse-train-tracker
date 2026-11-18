import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { SQLiteWatcherRepository } from "../src/cloudflare/sqlite-repository.js";

const dbPlatformSnapshot: TripSnapshot = {
  id: "eu:transitous:ice-742",
  source: "transitous",
  nativeId: "ice-742",
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

describe("Cloudflare platform shadow forecasting", () => {
  it("generates one default-deny shadow forecast and scores it from later final truth", async () => {
    const watcher = env.WATCHER.getByName("global");
    for (let index = 0; index < 30; index += 1) {
      const date = new Date(Date.UTC(2026, 0, index + 1, 12));
      const serviceDate = date.toISOString().slice(0, 10);
      const snapshot: TripSnapshot = {
        ...dbPlatformSnapshot,
        id: `eu:transitous:ice-742-history-${index}`,
        nativeId: `ice-742-history-${index}`,
        serviceDate,
        fetchedAt: `${serviceDate}T12:06:00.000Z`,
        stops: [{
          ...dbPlatformSnapshot.stops[0]!,
          scheduledArrival: `${serviceDate}T11:58:00.000Z`,
          scheduledDeparture: `${serviceDate}T12:00:00.000Z`,
          expectedArrival: `${serviceDate}T11:58:00.000Z`,
          expectedDeparture: `${serviceDate}T12:00:00.000Z`,
          expectedPlatform: index < 27 ? "8" : "9",
          platformObservedAt: `${serviceDate}T12:05:00.000Z`,
          passed: true,
        }],
      };
      expect(await watcher.recordPlatformSnapshot(snapshot, "watcher")).toBe(1);
    }

    const current: TripSnapshot = {
      ...dbPlatformSnapshot,
      id: "eu:transitous:ice-742-current",
      nativeId: "ice-742-current",
      serviceDate: "2026-08-01",
      fetchedAt: "2026-08-01T08:00:00.000Z",
      stops: [{
        ...dbPlatformSnapshot.stops[0]!,
        scheduledArrival: "2026-08-01T11:58:00.000Z",
        scheduledDeparture: "2026-08-01T12:00:00.000Z",
        expectedArrival: null,
        expectedDeparture: null,
        plannedPlatform: null,
        expectedPlatform: null,
        platformSource: null,
        platformObservedAt: null,
        passed: false,
      }],
    };

    const first = await watcher.forecastPlatformSnapshot(current, "2026-08-01T08:00:00.000Z");
    const repeated = await watcher.forecastPlatformSnapshot(current, "2026-08-01T08:05:00.000Z");
    expect("platformForecast" in first.stops[0]!).toBe(false);
    expect("platformForecast" in repeated.stops[0]!).toBe(false);

    let health = await watcher.health();
    expect(health).toMatchObject({
      platformShadowForecasts: 1,
      platformShadowOutcomes: 0,
      platformForecastLastGeneratedAt: "2026-08-01T08:00:00.000Z",
    });

    expect(await watcher.recordPlatformSnapshot({
      ...current,
      fetchedAt: "2026-08-01T12:06:00.000Z",
      stops: [{
        ...current.stops[0]!,
        expectedPlatform: "8",
        platformSource: "DB Timetables",
        platformObservedAt: "2026-08-01T12:05:00.000Z",
        passed: true,
      }],
    }, "watcher")).toBe(1);

    health = await watcher.health();
    expect(health).toMatchObject({
      platformShadowForecasts: 1,
      platformShadowOutcomes: 1,
    });
  });

  it("scores a shadow forecast when the normal watcher success path records final truth", async () => {
    const watcher = env.WATCHER.getByName("global");
    for (let index = 0; index < 5; index += 1) {
      const serviceDate = `2026-07-${String(index + 1).padStart(2, "0")}`;
      expect(await watcher.recordPlatformSnapshot({
        ...dbPlatformSnapshot,
        id: `eu:transitous:ice-742-watcher-history-${index}`,
        nativeId: `ice-742-watcher-history-${index}`,
        serviceDate,
        fetchedAt: `${serviceDate}T12:06:00.000Z`,
        stops: [{
          ...dbPlatformSnapshot.stops[0]!,
          scheduledArrival: `${serviceDate}T11:58:00.000Z`,
          scheduledDeparture: `${serviceDate}T12:00:00.000Z`,
          expectedArrival: `${serviceDate}T11:58:00.000Z`,
          expectedDeparture: `${serviceDate}T12:00:00.000Z`,
          expectedPlatform: "8",
          platformObservedAt: `${serviceDate}T12:05:00.000Z`,
          passed: true,
        }],
      }, "watcher")).toBe(1);
    }

    const current: TripSnapshot = {
      ...dbPlatformSnapshot,
      id: "eu:transitous:ice-742-watcher-current",
      nativeId: "ice-742-watcher-current",
      serviceDate: "2026-08-01",
      fetchedAt: "2026-08-01T08:00:00.000Z",
      stops: [{
        ...dbPlatformSnapshot.stops[0]!,
        scheduledArrival: "2026-08-01T11:58:00.000Z",
        scheduledDeparture: "2026-08-01T12:00:00.000Z",
        expectedArrival: null,
        expectedDeparture: null,
        plannedPlatform: null,
        expectedPlatform: null,
        platformSource: null,
        platformObservedAt: null,
        passed: false,
      }],
    };
    await watcher.forecastPlatformSnapshot(current, current.fetchedAt);
    const outcomesBeforeWatcherSuccess = (await watcher.health()).platformShadowOutcomes;

    await runInDurableObject(watcher, async (_instance, state) => {
      const repository = new SQLiteWatcherRepository(state.storage);
      await repository.recordSuccess(current.id, {
        ...current,
        fetchedAt: "2026-08-01T12:06:00.000Z",
        stops: [{
          ...current.stops[0]!,
          expectedPlatform: "8",
          platformSource: "DB Timetables",
          platformObservedAt: "2026-08-01T12:05:00.000Z",
          passed: true,
        }],
      }, 30, []);
    });

    expect((await watcher.health()).platformShadowOutcomes).toBe(outcomesBeforeWatcherSuccess + 1);
  });

  it("persists a completed sampled target and exposes sampler freshness", async () => {
    const watcher = env.WATCHER.getByName("global");
    const before = await watcher.health();
    const sampledAt = Date.parse("2026-08-23T08:30:00.000Z");

    await runInDurableObject(watcher, async (_instance, state) => {
      const repository = new SQLiteWatcherRepository(state.storage);
      const reference = {
        id: "eu:transitous:20260823_08:27_de-DELFI_ice-507-sampler",
        source: "transitous" as const,
        nativeId: "20260823_08:27_de-DELFI_ice-507-sampler",
        serviceDate: "2026-08-23",
      };
      const target = repository.enrollPlatformSample(reference, sampledAt, sampledAt - 30 * 60_000);
      expect(target).not.toBeNull();
      repository.recordPlatformSampleSuccess(target!, {
        ...dbPlatformSnapshot,
        ...reference,
        fetchedAt: "2026-08-23T08:30:00.000Z",
        stops: [{
          ...dbPlatformSnapshot.stops[0]!,
          scheduledArrival: "2026-08-23T08:25:00.000Z",
          scheduledDeparture: "2026-08-23T08:27:00.000Z",
          expectedArrival: "2026-08-23T08:25:00.000Z",
          expectedDeparture: "2026-08-23T08:27:00.000Z",
          platformObservedAt: "2026-08-23T08:29:00.000Z",
          passed: true,
        }],
      }, sampledAt + 15 * 60_000, true, sampledAt);
      repository.recordPlatformSamplingRun({
        discoveryAttempted: true,
        targetsEnrolled: 1,
        targetsPolled: 1,
        observationsRecorded: 1,
        failures: 0,
      }, sampledAt);
    });

    expect(await watcher.health()).toMatchObject({
      platformTrainingEvents: before.platformTrainingEvents + 1,
      platformSampleTargetsActive: before.platformSampleTargetsActive,
      platformSampleTargetsCompleted: before.platformSampleTargetsCompleted + 1,
      platformSampleLastRunAt: "2026-08-23T08:30:00.000Z",
      platformSampleLastSuccessAt: "2026-08-23T08:30:00.000Z",
    });
  });
});
