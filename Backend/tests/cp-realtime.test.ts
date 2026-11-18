import { describe, expect, it } from "vitest";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { CpRealtimeOverlay } from "../src/providers/cp-realtime.js";

const snapshot: TripSnapshot = {
  id: "eu:transitous:20260721_13:00_pt-Comboios-de-Portugal(CP)_132_20251214",
  source: "transitous",
  nativeId: "20260721_13:00_pt-Comboios-de-Portugal(CP)_132_20251214",
  serviceDate: "2026-07-21",
  operatorName: "CP",
  product: "AP",
  headsign: "Lisboa Santa Apolónia",
  fetchedAt: "2026-07-21T15:20:00.000Z",
  alertIds: [],
  stops: [{
    stationId: "eu:transitous:pt-Comboios-de-Portugal(CP)_94_31039",
    stationName: "Lisboa Oriente",
    countryCode: "PT",
    latitude: 38.767757,
    longitude: -9.099094,
    sequence: 1,
    scheduledArrival: "2026-07-21T15:22:00.000Z",
    scheduledDeparture: "2026-07-21T15:23:00.000Z",
    expectedArrival: "2026-07-21T15:22:00.000Z",
    expectedDeparture: "2026-07-21T15:23:00.000Z",
    plannedPlatform: null,
    expectedPlatform: null,
    platformSource: null,
    platformObservedAt: null,
    cancelled: false,
    passed: false,
  }, {
    stationId: "eu:transitous:pt-Comboios-de-Portugal(CP)_94_30007",
    stationName: "Lisboa Santa Apolónia",
    countryCode: "PT",
    latitude: 38.71584,
    longitude: -9.120748,
    sequence: 2,
    scheduledArrival: "2026-07-21T15:30:00.000Z",
    scheduledDeparture: null,
    expectedArrival: "2026-07-21T15:30:00.000Z",
    expectedDeparture: null,
    plannedPlatform: null,
    expectedPlatform: null,
    platformSource: null,
    platformObservedAt: null,
    cancelled: false,
    passed: false,
  }],
};

describe("CP official realtime overlay", () => {
  it("maps full-trip platforms, expected times, suppressions, disruptions, and position", async () => {
    const requests: Request[] = [];
    const overlay = new CpRealtimeOverlay(
      "api-key",
      "connect-id",
      "connect-secret",
      "https://example.test/travel-api",
      async (input, init) => {
        requests.push(new Request(input, init));
        return Response.json({
          trainNumber: 132,
          delay: 5,
          latitude: 39.1,
          longitude: -8.7,
          hasDisruptions: true,
          messages: [{ code: "work", text: "Engineering work" }],
          trainStops: [{
            station: { code: "94-31039", designation: "Lisboa Oriente" },
            arrival: "16:22",
            departure: "16:23",
            platform: "8",
            delay: 6,
            supression: null,
            ETA: "16:24",
            ETD: "16:28",
          }, {
            station: { code: "94-30007", designation: "Lisboa Santa Apolonia" },
            arrival: "16:30",
            departure: null,
            platform: "2",
            delay: 5,
            supression: true,
            ETA: "16:35",
            ETD: null,
          }],
        });
      },
      () => new Date("2026-07-21T15:20:20.000Z"),
    );

    const updates = await overlay.platformUpdates(snapshot);
    const alerts = await overlay.tripAlertIds(snapshot);
    const positions = await overlay.positionUpdates(snapshot);

    expect(requests).toHaveLength(1);
    expect(requests[0]!.url).toContain("/trains/132/timetable/2026-07-21");
    expect(requests[0]!.headers.get("x-api-key")).toBe("api-key");
    expect(updates[0]).toMatchObject({
      expectedPlatform: "8",
      expectedArrival: "2026-07-21T15:24:00.000Z",
      expectedDeparture: "2026-07-21T15:28:00.000Z",
      cancelled: false,
      source: "CP official realtime",
    });
    expect(updates[1]).toMatchObject({
      expectedPlatform: "2",
      expectedArrival: "2026-07-21T15:35:00.000Z",
      cancelled: true,
    });
    expect(alerts).toHaveLength(1);
    expect(alerts[0]).toMatch(/^cp-alert-132-2026-07-21-/u);
    expect(positions[0]).toMatchObject({
      latitude: 39.1,
      longitude: -8.7,
      source: "real",
      provider: "CP official realtime",
    });
  });

  it("does nothing when the Transitous trip cannot be matched to a CP train number", async () => {
    const overlay = new CpRealtimeOverlay("api-key", "connect-id", "connect-secret");
    const unmatched = { ...snapshot, nativeId: "pt-unknown-trip", product: "AP" };

    await expect(overlay.platformUpdates(unmatched)).resolves.toEqual([]);
  });
});
