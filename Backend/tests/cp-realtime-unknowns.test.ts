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
  }],
};

function overlay(train: Record<string, unknown>, now = () => new Date("2026-07-21T15:20:20.000Z")) {
  let requests = 0;
  const value = new CpRealtimeOverlay("key", "id", "secret", "https://example.test/travel-api", async () => {
    requests += 1;
    return Response.json(train);
  }, now);
  return { value, requests: () => requests };
}

const stopWithoutRealtime = {
  station: { code: "94-31039", designation: "Lisboa Oriente" },
  arrival: "16:22",
  departure: "16:23",
  platform: null,
  delay: null,
  supression: null,
  ETA: null,
  ETD: null,
};

describe("CP official realtime unknown values", () => {
  it("treats a null delay as no observation instead of on time", async () => {
    const { value } = overlay({ trainNumber: 132, delay: null, latitude: null, longitude: null, trainStops: [stopWithoutRealtime] });

    await expect(value.platformUpdates(snapshot)).resolves.toEqual([]);
  });

  it.each([
    [null, null],
    [0, 0],
    ["0", "0"],
    ["", ""],
    ["abc", -8.7],
    [139.1, -8.7],
  ])("reports no position for coordinates %j, %j", async (latitude, longitude) => {
    const { value } = overlay({ trainNumber: 132, latitude, longitude, trainStops: [] });

    await expect(value.positionUpdates(snapshot)).resolves.toEqual([]);
  });

  it("stamps observations with the fetch time, not the time the cache was read", async () => {
    let now = new Date("2026-07-21T15:20:20.000Z");
    const { value, requests } = overlay({
      trainNumber: 132,
      delay: 3,
      latitude: 39.1,
      longitude: -8.7,
      trainStops: [{ ...stopWithoutRealtime, delay: 3 }],
    }, () => now);

    await value.platformUpdates(snapshot);
    now = new Date("2026-07-21T15:20:30.000Z");
    const updates = await value.platformUpdates(snapshot);
    const positions = await value.positionUpdates(snapshot);

    expect(requests()).toBe(1);
    expect(updates[0]).toMatchObject({ expectedDeparture: "2026-07-21T15:26:00.000Z", observedAt: "2026-07-21T15:20:20.000Z" });
    expect(positions[0]?.asOf).toBe("2026-07-21T15:20:20.000Z");
  });
});
