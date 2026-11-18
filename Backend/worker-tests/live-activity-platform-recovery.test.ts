import { env } from "cloudflare:test";
import { runInInitializedWatcher as runInDurableObject } from "./initialized-watcher.js";
import { describe, expect, it } from "vitest";
import type { LiveActivityPush, LiveActivityRegistration } from "../src/domain/live-activity.js";
import { LiveActivityService } from "../src/cloudflare/live-activity-service.js";
import { IRailPlatformOverlay } from "../src/providers/irail.js";
import { TripSnapshotEnricher } from "../src/providers/platform-overlay.js";
import { ProviderRegistry } from "../src/providers/provider.js";
import { TransitousProvider } from "../src/providers/transitous.js";

// Exercise provider -> enrichment -> persisted trip cache -> activity store -> push outbox.
// Only the external rail HTTP boundary and APNs delivery use local fixtures.
function fixture(startedAt: number) {
  let now = startedAt;
  let platform: string | null = "9";
  const departure = startedAt + 10 * 60_000;
  const iso = (value: number) => new Date(value).toISOString();
  const place = (name: string, time: number) => ({ name, stopId: `be-${name}`, lat: 50.8, lon: 4.3,
    departure: iso(time), scheduledDeparture: iso(time), track: "2", scheduledTrack: "2" });
  const provider = new TransitousProvider("https://example.test", async () => Response.json({ legs: [{
    mode: "RAIL", tripId: "test-531", displayName: "IC 531", from: place("Brussels", departure), to: place("Gent", departure + 3_600_000),
  }] }), () => new Date(now));
  const overlay = new IRailPlatformOverlay("https://example.test", async () => {
    if (platform === null) throw new Error("fixture: official feed unavailable");
    return Response.json({ timestamp: String(now / 1_000), departures: { departure: [{
      time: String(departure / 1_000), delay: "0", vehicle: "IC 531", platform,
    }] } });
  }, () => new Date(now));
  const registry = new ProviderRegistry([provider], new TripSnapshotEnricher([overlay]));
  const input: LiveActivityRegistration = { schemaVersion: 1, installationId: crypto.randomUUID(), activityId: crypto.randomUUID(),
    token: "a".repeat(64), tokenGeneration: 1, environment: "sandbox",
    trip: { id: "test", source: "transitous", nativeId: "test-531", serviceDate: iso(startedAt).slice(0, 10) },
    boardingStationId: "eu:transitous:be-Brussels", alightingStationId: "eu:transitous:be-Gent",
    boardingStopSequence: 1, alightingStopSequence: 2, stationTimeZones: {}, startedAt: iso(startedAt),
    initialContentState: { schemaVersion: 1, phase: "departureSoon", focusName: "Brussels", eventTime: departure / 1_000,
      timeZoneIdentifier: null, timingBasis: "estimated", platform: "9", platformBasis: "reported", platformSource: "iRail",
      platformChanged: true, delayMinutes: 0, checkedAt: startedAt / 1_000, validUntil: startedAt / 1_000 + 300, isStopCancelled: false } };
  return { input, registry, set: (nextTime: number, nextPlatform: string | null) => { now = nextTime; platform = nextPlatform; } };
}
const context = { credentialHash: "c".repeat(64), clientKey: "platform-recovery" };

describe("Live Activity platform continuity", () => {
  it("honors explicit official platform suppression instead of retaining the last assignment", async () => {
    const now = Date.now();
    const setup = fixture(now);
    const official = await setup.registry.fetchTrip(setup.input.trip);
    const suppressed = { ...official, stops: official.stops.map((stop) => ({ ...stop,
      plannedPlatform: null, expectedPlatform: null, platformSource: "National Rail Darwin", platformObservedAt: new Date(now).toISOString(),
    })) };
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), async (_instance, state) => {
      const sent: LiveActivityPush[] = [];
      const service = new LiveActivityService(state.storage, { async fetchTrip() { return suppressed; } },
        { async send(push) { sent.push(push); } });
      expect(service.store.register(setup.input, context, now).allowed).toBe(true);
      await service.tick(now);
      expect(service.store.get(setup.input.activityId)?.content).toMatchObject({ platform: null, platformBasis: "unavailable" });
      expect(sent.at(-1)?.alert).toBeUndefined();
    });
  });

  it("keeps the last official platform through an overlay outage and announces the next genuine assignment", async () => {
    const now = Date.now();
    const setup = fixture(now);
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), async (_instance, state) => {
      const sent: LiveActivityPush[] = [];
      const service = new LiveActivityService(state.storage, setup.registry, { async send(push) { sent.push(push); } });
      expect(service.store.register(setup.input, context, now).allowed).toBe(true);
      await service.tick(now);
      setup.set(now + 60_000, null);
      await service.tick(now + 60_000);
      expect(service.store.get(setup.input.activityId)?.content).toMatchObject({ platform: "9", platformSource: "iRail" });
      expect(sent.at(-1)?.alert).toBeUndefined();
      // Timetable success must not renew the last operator observation's freshness.
      expect(service.store.get(setup.input.activityId)?.content.validUntil).toBeLessThanOrEqual(now / 1_000 + 300);
      setup.set(now + 120_000, "7");
      await service.tick(now + 120_000);
      expect(sent.at(-1)?.alert).toMatchObject({ title: "Platform changed to 7" });
      expect(service.store.get(setup.input.activityId)?.content).toMatchObject({ platform: "7", platformSource: "iRail" });
      expect(service.store.get(setup.input.activityId)?.content.validUntil).toBeGreaterThan(now / 1_000 + 300);
    });
  });

  it("protects the phone's official assignment when the first server check has no overlay", async () => {
    const now = Date.now();
    const setup = fixture(now);
    setup.set(now, null);
    await runInDurableObject(env.WATCHER.getByName(crypto.randomUUID()), async (_instance, state) => {
      const sent: LiveActivityPush[] = [];
      const service = new LiveActivityService(state.storage, setup.registry, { async send(push) { sent.push(push); } });
      expect(service.store.register(setup.input, context, now).allowed).toBe(true);
      await service.tick(now);
      expect(service.store.get(setup.input.activityId)?.content).toMatchObject({ platform: "9", platformSource: "iRail" });
      expect(sent.at(-1)?.alert).toBeUndefined();
      setup.set(now + 60_000, "7");
      await service.tick(now + 60_000);
      expect(sent.at(-1)?.alert).toMatchObject({ title: "Platform changed to 7" });
    });
  });
});
