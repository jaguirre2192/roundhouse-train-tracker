import { describe, expect, it } from "vitest";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import {
  carryForwardRecoveryPosition,
  shouldRetireTripWatch,
  tripWatchRecoveryCutoff,
} from "../src/domain/trip-watch-recovery.js";

const referenceDate = Date.parse("2026-09-12T16:00:00.000Z");

function snapshot(overrides: Partial<TripSnapshot["stops"][number]> = {}): TripSnapshot {
  return {
    id: "us:amtraker:171-12",
    source: "amtraker",
    nativeId: "171-12",
    serviceDate: "2026-09-12",
    operatorName: "Amtrak",
    product: "Northeast Regional 171",
    headsign: "Washington",
    fetchedAt: "2026-09-12T15:00:00.000Z",
    alertIds: [],
    stops: [{
      stationId: "us:amtraker:WAS",
      stationName: "Washington Union Station",
      countryCode: "US",
      latitude: 38.897,
      longitude: -77.006,
      sequence: 1,
      scheduledArrival: "2026-09-12T15:00:00.000Z",
      scheduledDeparture: null,
      expectedArrival: "2026-09-12T15:00:00.000Z",
      expectedDeparture: null,
      plannedPlatform: null,
      expectedPlatform: null,
      platformSource: null,
      platformObservedAt: null,
      cancelled: false,
      passed: true,
      ...overrides,
    }],
  };
}

describe("trip watch recovery", () => {
  it("keeps an all-passed snapshot active through the two-hour recovery window", () => {
    const trip = snapshot();

    expect(tripWatchRecoveryCutoff(trip)).toBe(Date.parse("2026-09-12T17:00:00.000Z"));
    expect(shouldRetireTripWatch(trip, referenceDate)).toBe(false);
    expect(shouldRetireTripWatch(trip, Date.parse("2026-09-12T17:00:00.000Z"))).toBe(false);
    expect(shouldRetireTripWatch(trip, Date.parse("2026-09-12T17:00:00.001Z"))).toBe(true);
  });

  it("uses the latest expected time and eventually retires unpassed snapshots", () => {
    const delayed = snapshot({ expectedArrival: "2026-09-12T18:00:00.000Z" });
    const incomplete = snapshot({ passed: false });

    expect(shouldRetireTripWatch(delayed, Date.parse("2026-09-12T19:00:00.000Z"))).toBe(false);
    expect(shouldRetireTripWatch(incomplete, Date.parse("2026-09-12T17:00:00.000Z"))).toBe(false);
    expect(shouldRetireTripWatch(incomplete, Date.parse("2026-09-12T17:00:00.001Z"))).toBe(true);
  });

  it("bounds untimed and empty snapshots by their UTC service day", () => {
    const untimed = snapshot({
      scheduledArrival: null,
      scheduledDeparture: null,
      expectedArrival: null,
      expectedDeparture: null,
    });
    const empty = { ...untimed, stops: [] };

    for (const trip of [untimed, empty]) {
      expect(shouldRetireTripWatch(trip, Date.parse("2026-09-13T23:59:59.999Z"))).toBe(false);
      expect(shouldRetireTripWatch(trip, Date.parse("2026-09-14T00:00:00.001Z"))).toBe(true);
    }
  });
  it("keeps a delayed train polling from real position time, not its old timetable or HTTP check", () => {
    const now = Date.parse("2026-09-12T20:00:00.000Z");
    const trip = { ...snapshot(), fetchedAt: new Date(now).toISOString(), positions: [{
      latitude: 39.5, longitude: -76.5, heading: null, source: "real" as const,
      confidence: 1, asOf: new Date(now - 60_000).toISOString(), provider: "Amtraker",
    }] };
    const cutoff = now - 60_000 + 2 * 60 * 60_000;
    expect(tripWatchRecoveryCutoff(trip, now)).toBe(cutoff);
    expect(shouldRetireTripWatch(trip, now)).toBe(false);
    expect(shouldRetireTripWatch(trip, cutoff)).toBe(false);
    expect(shouldRetireTripWatch({ ...trip, fetchedAt: new Date(cutoff + 1).toISOString() }, cutoff + 1)).toBe(true);
  });

  it("rejects inferred, stale, invalid and implausibly future position extensions", () => {
    const now = Date.parse("2026-09-12T20:00:00.000Z");
    const position = { latitude: 39.5, longitude: -76.5, heading: null, source: "real" as const,
      confidence: 1, asOf: new Date(now).toISOString(), provider: "Amtraker" };
    const invalid = [
      { ...position, source: "inferred" as const },
      { ...position, asOf: new Date(now - 2 * 60 * 60_000 - 1).toISOString() },
      { ...position, asOf: new Date(now + 120_001).toISOString() },
      { ...position, asOf: "invalid" },
      { ...position, confidence: 0 },
      { ...position, latitude: 91 },
      { ...position, latitude: 0, longitude: 0 },
    ];
    for (const value of invalid) {
      expect(shouldRetireTripWatch({ ...snapshot(), fetchedAt: new Date(now).toISOString(), positions: [value] }, now)).toBe(true);
    }
  });

  it("carries recovery evidence through a missing overlay without renewing or crossing identities", () => {
    const now = Date.parse("2026-09-12T20:00:00.000Z");
    const position = { latitude: 39.5, longitude: -76.5, heading: null, source: "real" as const,
      confidence: 1, asOf: new Date(now - 60_000).toISOString(), provider: "Amtraker" };
    const previous = { ...snapshot(), positions: [position] };
    const current = { ...snapshot(), fetchedAt: new Date(now).toISOString() };
    const retained = carryForwardRecoveryPosition(previous, current, now);
    expect(retained.positions).toEqual([position]);
    expect(shouldRetireTripWatch(retained, now)).toBe(false);
    expect(carryForwardRecoveryPosition(previous, current, now + 2 * 60 * 60_000).positions).toBeUndefined();
    expect(carryForwardRecoveryPosition(previous, { ...current, serviceDate: "2026-09-13" }, now).positions).toBeUndefined();
    expect(carryForwardRecoveryPosition(previous, { ...current, nativeId: "other" }, now).positions).toBeUndefined();
    const fresh = { ...position, asOf: new Date(now).toISOString(), latitude: 39.4 };
    expect(carryForwardRecoveryPosition(previous, { ...current, positions: [fresh] }, now).positions).toEqual([fresh]);
  });

  it("grants bounded recovery to intermediate stop observations, not legacy flags or renewed terminal reports", () => {
    const now = Date.parse("2026-09-12T20:00:00.000Z");
    const observed = new Date(now - 60_000).toISOString();
    const inTransit = (evidence: Partial<TripSnapshot["stops"][number]>) => {
      const base = snapshot(evidence);
      return { ...base, stops: [base.stops[0]!, { ...snapshot().stops[0]!, stationId: "us:amtraker:END", sequence: 2 }] };
    };
    expect(shouldRetireTripWatch(inTransit({ passed: true, passageObservedAt: observed }), now)).toBe(false);
    expect(shouldRetireTripWatch(inTransit({ passed: false, arrivalObservedAt: observed }), now)).toBe(false);
    expect(shouldRetireTripWatch(inTransit({ passed: false, passageObservedAt: observed }), now)).toBe(true);
    expect(shouldRetireTripWatch(inTransit({ passed: true }), now)).toBe(true);
    expect(shouldRetireTripWatch(inTransit({ passageObservedAt: observed }), now + 2 * 60 * 60_000)).toBe(true);
    expect(shouldRetireTripWatch(inTransit({ arrivalObservedAt: new Date(now + 120_001).toISOString() }), now)).toBe(true);
    // An arrived train still publishing GPS/status must eventually leave the watch list.
    const arrived = { ...snapshot({ arrivalObservedAt: observed }), positions: [{
      latitude: 38.897, longitude: -77.006, heading: null, source: "real" as const,
      confidence: 1, asOf: new Date(now).toISOString(), provider: "Amtraker",
    }] };
    expect(shouldRetireTripWatch(arrived, now)).toBe(true);
  });

  it("preserves actual terminal arrival beside new GPS but keeps polling when GPS is still before it", () => {
    const now = Date.parse("2026-09-12T20:00:00.000Z");
    const base = snapshot({ latitude: 39, longitude: -77,
      arrivalObservedAt: new Date(now - 60_000).toISOString() });
    const trip = { ...base, stops: [{ ...base.stops[0]!, stationId: "origin", sequence: 0,
      latitude: 40,
      scheduledDeparture: "2026-09-12T10:00:00Z" }, base.stops[0]!] };
    delete trip.stops[0]!.arrivalObservedAt;
    const fix = { latitude: 39, longitude: -77, heading: null, source: "real" as const,
      confidence: 1, asOf: new Date(now).toISOString(), provider: "Amtraker" };
    expect(shouldRetireTripWatch({ ...trip, positions: [fix] }, now)).toBe(true);
    expect(shouldRetireTripWatch({ ...trip, positions: [{ ...fix, latitude: 39.5 }] }, now)).toBe(false);
  });

});
