import { describe, expect, it } from "vitest";
import { pollIntervalSeconds } from "../src/domain/cadence.js";
import type { TripSnapshot } from "../src/domain/snapshot.js";

describe("pollIntervalSeconds", () => {
  it("uses the fast lane for country-specific platform sources", () => {
    expect(pollIntervalSeconds("sncf", "platform", null)).toBe(20);
    expect(pollIntervalSeconds("db", "platform", null)).toBe(20);
  });

  it("uses the fast lane when a unified trip has a connected country overlay", () => {
    const snapshot: TripSnapshot = {
      id: "eu:transitous:be-test",
      source: "transitous",
      nativeId: "be-test",
      serviceDate: "2026-07-21",
      operatorName: "SNCB",
      product: "IC 1234",
      headsign: "Brussels",
      fetchedAt: "2026-07-21T10:00:00.000Z",
      alertIds: [],
      stops: [{
        stationId: "eu:transitous:be-test-brussels",
        stationName: "Brussels",
        countryCode: "BE",
        latitude: 50.845,
        longitude: 4.357,
        sequence: 1,
        scheduledArrival: null,
        scheduledDeparture: "2026-07-21T12:00:00.000Z",
        expectedArrival: null,
        expectedDeparture: "2026-07-21T12:00:00.000Z",
        plannedPlatform: null,
        expectedPlatform: null,
        platformSource: null,
        platformObservedAt: null,
        cancelled: false,
        passed: false,
      }],
    };
    expect(pollIntervalSeconds("transitous", "platform", snapshot)).toBe(20);
    expect(pollIntervalSeconds("transitous", "platform", {
      ...snapshot,
      stops: snapshot.stops.map((stop) => ({ ...stop, countryCode: "FI" })),
    })).toBe(20);
    expect(pollIntervalSeconds("transitous", "platform", {
      ...snapshot,
      stops: snapshot.stops.map((stop) => ({ ...stop, countryCode: "NO" })),
    })).toBe(20);
    expect(pollIntervalSeconds("transitous", "platform", {
      ...snapshot,
      stops: snapshot.stops.map((stop) => ({ ...stop, countryCode: "AU" })),
    })).toBe(20);
    expect(pollIntervalSeconds("transitous", "platform", {
      ...snapshot,
      stops: snapshot.stops.map((stop) => ({ ...stop, countryCode: "PL" })),
    })).toBe(20);
  });

  it("backs off full-trip polling without a current departure", () => {
    expect(pollIntervalSeconds("amtraker", "full-trip", null)).toBe(120);
  });

  it("keeps scheduled-only Japanese timetable data on a low-frequency lane", () => {
    expect(pollIntervalSeconds("ekispert", "platform", null)).toBe(900);
    expect(pollIntervalSeconds("ekispert", "full-trip", null)).toBe(900);
  });

  it("does not poll the Serbian booking timetable as a live feed", () => {
    expect(pollIntervalSeconds("srbijavoz", "platform", null)).toBe(900);
    expect(pollIntervalSeconds("srbijavoz", "full-trip", null)).toBe(900);
  });
});
