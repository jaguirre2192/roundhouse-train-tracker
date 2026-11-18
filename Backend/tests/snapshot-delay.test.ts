import { describe, expect, it } from "vitest";
import { delayMinutes, type StopSnapshot } from "../src/domain/snapshot.js";

function stop(overrides: Partial<StopSnapshot>): StopSnapshot {
  return {
    stationId: "eu:transitous:test",
    stationName: "Test",
    countryCode: "DE",
    latitude: null,
    longitude: null,
    sequence: 2,
    scheduledArrival: "2026-07-21T10:00:00.000Z",
    scheduledDeparture: "2026-07-21T10:10:00.000Z",
    expectedArrival: null,
    expectedDeparture: null,
    plannedPlatform: null,
    expectedPlatform: null,
    platformSource: null,
    platformObservedAt: null,
    cancelled: false,
    passed: false,
    ...overrides,
  };
}

describe("delayMinutes", () => {
  it("compares an expected arrival with the scheduled arrival, not the departure", () => {
    // 4 minutes late on arrival; against the 10:10 departure it would look 6 minutes early.
    expect(delayMinutes(stop({ expectedArrival: "2026-07-21T10:04:00.000Z" }))).toBe(4);
  });

  it("prefers the departure pair when both departure times are known", () => {
    expect(delayMinutes(stop({
      expectedArrival: "2026-07-21T10:04:00.000Z",
      expectedDeparture: "2026-07-21T10:17:00.000Z",
    }))).toBe(7);
  });

  it("returns null rather than mixing an expected departure with a scheduled arrival", () => {
    expect(delayMinutes(stop({
      scheduledDeparture: null,
      expectedDeparture: "2026-07-21T10:17:00.000Z",
    }))).toBeNull();
  });
});
