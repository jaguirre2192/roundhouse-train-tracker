import { afterEach, describe, expect, it, vi } from "vitest";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { TripSnapshotEnricher, type PlatformRealtimeOverlay } from "../src/providers/platform-overlay.js";

const snapshot: TripSnapshot = {
  id: "eu:transitous:feed-test", source: "transitous", nativeId: "feed-test",
  serviceDate: "2026-11-13", operatorName: "Test", product: "IC 1", headsign: "Terminus",
  fetchedAt: "2026-11-13T12:00:00Z", alertIds: [],
  stops: [{ stationId: "station-1", stationName: "Origin", countryCode: "FR",
    latitude: 48, longitude: 2, sequence: 1,
    scheduledArrival: null, scheduledDeparture: "2026-11-13T12:10:00Z",
    expectedArrival: null, expectedDeparture: "2026-11-13T12:10:00Z",
    plannedPlatform: "1", expectedPlatform: "1", platformSource: null,
    platformObservedAt: null, cancelled: false, passed: false }],
};

afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); });

describe("independent realtime feeds", () => {
  it("retains a timely alert when the same provider's timing request never returns", async () => {
    vi.useFakeTimers();
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    const overlay: PlatformRealtimeOverlay = {
      sourceName: "Independent official feeds", supportedCountryCodes: new Set(["FR"]),
      platformUpdates: () => new Promise(() => {}),
      tripAlertIds: () => new Promise((resolve) => setTimeout(() => resolve(["disruption-1"]), 10)),
    };
    const pending = new TripSnapshotEnricher([overlay], [], 50).enrich(snapshot);
    await vi.advanceTimersByTimeAsync(50);
    const value = await pending;
    expect(value.alertIds).toEqual(["disruption-1"]);
    expect(value.stops).toEqual(snapshot.stops);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("retains timing and platform changes when the separate alert request stalls", async () => {
    vi.useFakeTimers();
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    const overlay: PlatformRealtimeOverlay = {
      sourceName: "Independent official feeds", supportedCountryCodes: new Set(["FR"]),
      platformUpdates: async () => [{ stopSequence: 1, stationId: "station-1",
        expectedDeparture: "2026-11-13T12:25:00Z", expectedPlatform: "4",
        observedAt: snapshot.fetchedAt, source: "Official timing feed" }],
      tripAlertIds: () => new Promise(() => {}),
    };
    const pending = new TripSnapshotEnricher([overlay], [], 50).enrich(snapshot);
    await vi.advanceTimersByTimeAsync(50);
    const value = await pending;
    expect(value.stops[0]).toMatchObject({ expectedPlatform: "4",
      expectedDeparture: "2026-11-13T12:25:00Z", passed: false });
    expect(value.alertIds).toEqual([]);
    expect(vi.getTimerCount()).toBe(0);
  });
});
