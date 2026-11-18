import { describe, expect, it } from "vitest";
import type { TripSnapshot, StopSnapshot } from "../src/domain/snapshot.js";
import { assessTripCoverage, failedTripCoverage } from "../src/services/trip-coverage-assessment.js";

const now = new Date("2026-11-13T22:00:00Z");
function stop(changes: Partial<StopSnapshot> = {}): StopSnapshot {
  return { stationId: "eu:transitous:dk-rejseplanen_1", stationName: "København H", countryCode: "DK",
    latitude: 55.67, longitude: 12.56, sequence: 1, scheduledArrival: null,
    scheduledDeparture: "2026-11-13T23:00:00Z", expectedArrival: null,
    expectedDeparture: "2026-11-13T23:00:00Z", plannedPlatform: "1", expectedPlatform: "1",
    platformSource: "Transitous", platformObservedAt: null, cancelled: false, passed: false, ...changes };
}
function trip(changes: Partial<TripSnapshot> = {}): TripSnapshot {
  return { id: "rail:transitous:dk:1", source: "transitous",
    nativeId: "20261113_23:00_dk-rejseplanen_1", serviceDate: "2026-11-13",
    operatorName: "DSB", product: "IC 1", headsign: "Aarhus", fetchedAt: now.toISOString(),
    stops: [stop()], alertIds: [], ...changes };
}

describe("consumer coverage observation boundaries", () => {
  it("never treats copied timetable times/platforms and false flags as live evidence", () => {
    const value = assessTripCoverage(trip(), undefined, now);
    expect(value.features.delays).toEqual({ support: "unknown", availability: "notObserved", observedAt: null });
    expect(value.features.platforms.availability).toBe("notObserved");
    expect(value.features.cancellations.support).toBe("unknown");
    expect(value.features.position).toEqual({ support: "notProvided", availability: "notObserved", observedAt: null });
  });

  it("retains uncertainty without inventing an outage when an optional observation is absent", () => {
    const value = assessTripCoverage(trip(), undefined, now);
    expect(Object.values(value.features).every((feature) => feature.availability === "notObserved")).toBe(true);
    expect(value.assessedAt).toBe(now.toISOString());
    expect(value.reviewedAt).toBe("2026-11-13");
  });

  it("scopes a changed forecast and explicit cancellation to the selected service", () => {
    const value = assessTripCoverage(trip({ stops: [stop({ expectedDeparture: "2026-11-13T23:10:00Z", cancelled: true })] }), undefined, now);
    expect(value.features.delays).toEqual({ support: "connected", availability: "observed", observedAt: null });
    expect(value.features.cancellations.availability).toBe("observed");
    expect(value.features.position.support).toBe("notProvided");
    expect(value.limitationCodes).toContain("currentObservationOnly");
  });

  it("does not renew stale forecast evidence with assessment time", () => {
    const value = assessTripCoverage(trip({ fetchedAt: "2026-11-13T21:00:00Z",
      stops: [stop({ expectedDeparture: "2026-11-13T23:10:00Z", cancelled: true })] }), undefined, now);
    expect(value.features.delays.availability).toBe("notObserved");
    expect(value.features.cancellations.availability).toBe("notObserved");
  });

  it("requires attributed current platform evidence and preserves its original clock", () => {
    const observedAt = "2026-11-13T21:59:20Z";
    const value = assessTripCoverage(trip({ stops: [stop({ expectedPlatform: "2", platformSource: "Official rail source", platformObservedAt: observedAt })] }), undefined, now);
    expect(value.features.platforms).toEqual({ support: "connected", availability: "observed", observedAt });
  });

  it("does not turn a freshly retrieved planned-platform fallback into an observation", () => {
    const value = assessTripCoverage(trip({ stops: [stop({ platformSource: "NS Reisinformatie",
      platformObservedAt: now.toISOString(), plannedPlatform: "8", expectedPlatform: "8" })] }), undefined, now);
    expect(value.features.platforms).toEqual({ support: "unknown", availability: "notObserved", observedAt: null });
  });

  it("never turns an old Amtrak point into a currently observed position", () => {
    const value = assessTripCoverage(trip({ source: "amtraker", nativeId: "55", positions: [{
      latitude: 40, longitude: -74, heading: null, source: "real", confidence: 1,
      asOf: "2026-11-13T21:20:00Z", provider: "Amtraker" }] }), undefined, now);
    expect(value.features.position.support).toBe("connected");
    expect(value.features.position.availability).toBe("notObserved");
    expect(value.features.position.observedAt).toBeNull();
  });

  it.each(["2026-11-13T21:54:59Z", "2026-11-13T22:02:01Z", "invalid"])("withholds invalid position clock %s", (asOf) => {
    const value = assessTripCoverage(trip({ positions: [{ latitude: 55, longitude: 12, heading: null,
      source: "real", confidence: 1, asOf, provider: "Test source" }] }), undefined, now);
    expect(value.features.position.availability).toBe("notObserved");
  });

  it("keeps a fresh real point's own observation time, not the fetch clock", () => {
    const asOf = "2026-11-13T21:59:15Z";
    const value = assessTripCoverage(trip({ positions: [{ latitude: 55, longitude: 12, heading: null,
      source: "real", confidence: 1, asOf, provider: "Test source" }] }), undefined, now);
    expect(value.features.position).toEqual({ support: "connected", availability: "observed", observedAt: asOf });
  });

  it("does not infer a country-wide policy for a mixed-country selected service", () => {
    const value = assessTripCoverage(trip({ stops: [stop(), stop({ countryCode: "DE", sequence: 2 })] }), undefined, now);
    expect(value.countryCodes).toEqual(["DE", "DK"]);
    expect(value.features.position.support).toBe("unknown");
  });

  it("distinguishes an explicit unavailable provider from a missing service without leaking IDs", () => {
    const reference = trip();
    const unavailable = failedTripCoverage(reference, true, now);
    const missing = failedTripCoverage(reference, false, now);
    expect(Object.values(unavailable.features).every((value) => value.support === "unknown" && value.availability === "unavailable")).toBe(true);
    expect(Object.values(missing.features).every((value) => value.availability === "notObserved")).toBe(true);
    expect(unavailable.countryCodes).toEqual(["DK"]);
    expect(JSON.stringify(unavailable)).not.toContain(reference.nativeId);
  });
});
