import { env } from "cloudflare:test";
import { runInInitializedWatcher as runInDurableObject } from "./initialized-watcher.js";
import { describe, expect, it } from "vitest";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { SQLiteWatcherRepository } from "../src/cloudflare/sqlite-repository.js";

describe("subscription recovery", () => {
  it("reenrolls a migrated phone without claiming the original device or its subscriptions", async () => {
    await runInDurableObject(env.WATCHER.getByName("migrated-device-recovery"), async (_instance, state) => {
      const repository = new SQLiteWatcherRepository(state.storage);
      const now = Date.now();
      const originalId = "da141c63-e992-48ed-8c46-86cb6d42586b";
      const recoveredId = "ea141c63-e992-48ed-8c46-86cb6d42586b";
      const originalContext = { credentialHash: "c".repeat(64), clientKey: "original-phone" };
      const migratedContext = { credentialHash: "d".repeat(64), clientKey: "migrated-phone" };
      const originalDevice = {
        installationId: originalId, token: "a".repeat(64),
        environment: "production" as const, platform: "ios" as const,
      };
      const subscription = {
        installationId: originalId,
        trip: { id: "eu:transitous:migration", source: "transitous" as const,
          nativeId: "migration", serviceDate: new Date(now).toISOString().slice(0, 10) },
        boardingStationId: "eu:transitous:avignon", alightingStationId: "eu:transitous:cdg",
        watchFrom: new Date(now).toISOString(),
        preferences: { delayThresholdMinutes: 5, platformChanges: true, cancellations: true, disruptions: true },
      };
      expect(repository.registerDevice(originalDevice, originalContext, now)).toEqual({ allowed: true });
      expect(repository.subscribe(subscription, originalContext, now)).toEqual({ allowed: true });
      const migratedDevice = { ...originalDevice, token: "b".repeat(64) };
      expect(repository.registerDevice(migratedDevice, migratedContext, now)).toEqual({ allowed: false, reason: "unauthorized" });
      expect(repository.registerDevice(migratedDevice, migratedContext, now)).toEqual({ allowed: false, reason: "unauthorized" });
      expect(repository.registerDevice({ ...migratedDevice, installationId: recoveredId }, migratedContext, now)).toEqual({ allowed: true });
      expect(repository.subscribe({ ...subscription, installationId: recoveredId }, migratedContext, now)).toEqual({ allowed: true });
      expect(repository.unsubscribe(originalId, subscription.trip.id, migratedContext, now)).toEqual({ allowed: false, reason: "unauthorized" });
      expect(state.storage.sql.exec<{ credential_hash: string }>(
        "SELECT credential_hash FROM devices WHERE installation_id = ?", originalId,
      ).one().credential_hash).toBe(originalContext.credentialHash);
      expect(state.storage.sql.exec<{ active: number }>(
        "SELECT active FROM subscriptions WHERE installation_id = ?", originalId,
      ).one().active).toBe(1);
      expect(repository.health().activeSubscriptions).toBe(2);
    });
  });

  it("keeps an all-passed watch through recovery and retires it after the cutoff", async () => {
    const watcher = env.WATCHER.getByName("subscription-recovery-window");
    await runInDurableObject(watcher, async (_instance, state) => {
      const repository = new SQLiteWatcherRepository(state.storage);
      const now = Date.now();
      const installationId = "ba141c63-e992-48ed-8c46-86cb6d42586b";
      const trip = {
        id: "us:amtraker:171-recovery",
        source: "amtraker" as const,
        nativeId: "171-recovery",
        serviceDate: new Date(now).toISOString().slice(0, 10),
      };
      const watchId = `${trip.id}@${trip.serviceDate}`;
      const context = {
        credentialHash: "c".repeat(64),
        clientKey: "subscription-recovery-client",
      };
      const device = {
        installationId,
        token: "a".repeat(64),
        environment: "sandbox" as const,
        platform: "ios" as const,
      };
      const subscription = {
        installationId,
        trip,
        boardingStationId: "us:amtraker:NYP",
        alightingStationId: "us:amtraker:WAS",
        watchFrom: new Date(now - 60_000).toISOString(),
        preferences: {
          delayThresholdMinutes: 5,
          platformChanges: true,
          cancellations: true,
          disruptions: true,
        },
      };
      expect(repository.registerDevice(device, context, now)).toEqual({ allowed: true });
      expect(repository.subscribe(subscription, context, now)).toEqual({ allowed: true });

      const makeSnapshot = (latestTime: number, passed = true): TripSnapshot => ({
        ...trip,
        operatorName: "Amtrak",
        product: "Northeast Regional 171",
        headsign: "Washington",
        fetchedAt: new Date(now).toISOString(),
        alertIds: [],
        stops: [{
          stationId: "us:amtraker:WAS",
          stationName: "Washington Union Station",
          countryCode: "US",
          latitude: 38.897,
          longitude: -77.006,
          sequence: 1,
          scheduledArrival: new Date(latestTime).toISOString(),
          scheduledDeparture: null,
          expectedArrival: new Date(latestTime).toISOString(),
          expectedDeparture: null,
          plannedPlatform: null,
          expectedPlatform: null,
          platformSource: null,
          platformObservedAt: null,
          cancelled: false,
          passed,
        }],
      });

      await repository.recordSuccess(watchId, makeSnapshot(now - 60 * 60_000), 30, []);
      expect(repository.health().activeSubscriptions).toBe(1);

      await repository.recordSuccess(watchId, makeSnapshot(now - 3 * 60 * 60_000, false), 30, []);
      expect(repository.health().activeSubscriptions).toBe(0);
    });
  });
});
