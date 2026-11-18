import { describe, expect, it, vi } from "vitest";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { TripSnapshotEnricher, type PlatformRealtimeOverlay } from "../src/providers/platform-overlay.js";

const snapshot: TripSnapshot = {
  id: "eu:transitous:be-test-1234",
  source: "transitous",
  nativeId: "be-test-1234",
  serviceDate: "2026-07-21",
  operatorName: "SNCB",
  product: "IC 1234",
  headsign: "Brussels",
  fetchedAt: "2026-07-21T10:00:00.000Z",
  alertIds: [],
  stops: [{
    stationId: "eu:transitous:be-test-antwerp",
    stationName: "Antwerp-Central",
    countryCode: "BE",
    latitude: 51.2172,
    longitude: 4.4211,
    sequence: 1,
    scheduledArrival: null,
    scheduledDeparture: "2026-07-21T10:05:00.000Z",
    expectedArrival: null,
    expectedDeparture: "2026-07-21T10:05:00.000Z",
    plannedPlatform: "4",
    expectedPlatform: "4",
    platformSource: "Transitous",
    platformObservedAt: null,
    cancelled: false,
    passed: false,
  }],
};

describe("TripSnapshotEnricher", () => {
  it("uses the newest country overlay and records provenance", async () => {
    const overlay: PlatformRealtimeOverlay = {
      sourceName: "iRail",
      supportedCountryCodes: new Set(["BE"]),
      platformUpdates: async () => [{
        stopSequence: 1,
        stationId: snapshot.stops[0]!.stationId,
        plannedPlatform: "4",
        expectedPlatform: "6",
        observedAt: "2026-07-21T10:00:10.000Z",
        source: "iRail",
      }],
    };

    const value = await new TripSnapshotEnricher([overlay]).enrich(snapshot);

    expect(value.stops[0]).toMatchObject({
      plannedPlatform: "4",
      expectedPlatform: "6",
      platformSource: "iRail",
      platformObservedAt: "2026-07-21T10:00:10.000Z",
    });
  });

  it("keeps the baseline snapshot when an overlay is unavailable", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const overlay: PlatformRealtimeOverlay = {
      sourceName: "iRail",
      supportedCountryCodes: new Set(["BE"]),
      platformUpdates: async () => { throw new Error("offline"); },
    };

    await expect(new TripSnapshotEnricher([overlay]).enrich(snapshot)).resolves.toEqual(snapshot);
    expect(error).toHaveBeenCalledOnce();
    error.mockRestore();
  });

  it("merges independently timed platform, delay, cancellation, and alert observations", async () => {
    const overlay: PlatformRealtimeOverlay = {
      sourceName: "Official rail feed",
      supportedCountryCodes: new Set(["BE"]),
      platformUpdates: async () => [{
        stopSequence: 1,
        stationId: snapshot.stops[0]!.stationId,
        expectedDeparture: "2026-07-21T10:12:00.000Z",
        cancelled: true,
        observedAt: "2026-07-21T10:00:20.000Z",
        source: "Official trip updates",
      }, {
        stopSequence: 1,
        stationId: snapshot.stops[0]!.stationId,
        expectedPlatform: "8",
        observedAt: "2026-07-21T10:00:10.000Z",
        source: "Official vehicle positions",
      }],
      tripAlertIds: async () => ["official-alert-1"],
    };

    const value = await new TripSnapshotEnricher([overlay]).enrich(snapshot);

    expect(value.alertIds).toEqual(["official-alert-1"]);
    expect(value.stops[0]).toMatchObject({
      expectedDeparture: "2026-07-21T10:12:00.000Z",
      expectedPlatform: "8",
      cancelled: true,
      platformSource: "Official vehicle positions",
      platformObservedAt: "2026-07-21T10:00:10.000Z",
    });
  });

  it("recomputes passed state when an official overlay changes the expected event time", async () => {
    const overlay: PlatformRealtimeOverlay = {
      sourceName: "Official rail feed",
      supportedCountryCodes: new Set(["BE"]),
      platformUpdates: async () => [{
        stopSequence: 1,
        stationId: snapshot.stops[0]!.stationId,
        expectedDeparture: "2026-07-21T10:12:00.000Z",
        observedAt: "2026-07-21T10:00:10.000Z",
        source: "Official trip updates",
      }],
    };
    const prematurelyPassed = {
      ...snapshot,
      stops: [{
        ...snapshot.stops[0]!,
        expectedDeparture: "2026-07-21T09:59:00.000Z",
        passed: true,
      }],
    };

    const value = await new TripSnapshotEnricher([overlay]).enrich(prematurelyPassed);

    expect(value.stops[0]).toMatchObject({
      expectedDeparture: "2026-07-21T10:12:00.000Z",
      passed: false,
    });
  });
});
