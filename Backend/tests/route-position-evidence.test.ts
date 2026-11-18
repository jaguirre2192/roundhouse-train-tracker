import { describe, expect, it } from "vitest";
import { projectLiveActivity } from "../src/domain/live-activity-projection.js";
import { routePositionEvidence } from "../src/domain/route-position-evidence.js";
import type { StopSnapshot, TripSnapshot, VehiclePositionSnapshot } from "../src/domain/snapshot.js";
import { encodePolyline5 } from "../src/providers/encoded-polyline.js";

const now = 1_784_000_000;
const iso = (offset = 0) => new Date((now + offset) * 1_000).toISOString();
function stop(name: string, sequence: number, longitude: number, offset: number): StopSnapshot {
  return { stationId: `eu:transitous:${name}`, stationName: name, countryCode: "ES", sequence,
    latitude: 40, longitude, scheduledArrival: iso(offset), scheduledDeparture: iso(offset),
    expectedArrival: null, expectedDeparture: null, plannedPlatform: null, expectedPlatform: null,
    platformSource: null, platformObservedAt: null, passed: false, cancelled: false };
}
function position(longitude = -3.98, offset = 0): VehiclePositionSnapshot {
  return { latitude: 40, longitude, asOf: iso(offset), source: "real", heading: null, confidence: 1, provider: "Renfe" };
}
function trip(fix = position()): TripSnapshot {
  return { id: "eu:transitous:es-test", source: "transitous", nativeId: "es-test", serviceDate: iso().slice(0, 10),
    operatorName: "Renfe", product: "AVE", headsign: "Destination", fetchedAt: iso(), alertIds: [], positions: [fix],
    stops: [stop("Origin", 1, -4, -3_600), stop("Middle", 2, -3.9, -1_800), stop("Destination", 3, -3.8, -600)] };
}
function project(value: TripSnapshot, alightingStationId?: string) {
  return projectLiveActivity({ trip: value, referenceDate: now, lastSuccessfulCheck: now,
    refreshFailed: false, stationTimeZones: {}, ...(alightingStationId === undefined ? {} : { alightingStationId }) });
}

describe("route position evidence parity with Core", () => {
  it("keeps delayed Spanish GPS focused on the actual next intermediate station after timetable arrival", () => {
    const result = project(trip());
    expect(result.state.phase).toBe("underway");
    expect(result.state.focusName).toBe("Middle");
    expect(result.shouldEnd).toBe(false);
    expect(result.nextTransitionDate).toBe(now + 300);
  });

  it("does not infer terminal arrival from a nearby fix but preserves an explicit earlier arrival", () => {
    for (const longitude of [-3.8, -3.803]) {
      const value = trip(position(longitude));
      expect(project(value).state.phase).toBe("underway");
      value.stops.at(-1)!.arrivalObservedAt = iso(-120);
      expect(project(value).state.phase).toBe("ended");
    }
    const before = trip(position(-3.82));
    before.stops.at(-1)!.arrivalObservedAt = iso(-120);
    expect(project(before).state.phase).toBe("underway");
    before.stops.at(-1)!.passed = true;
    before.stops.at(-1)!.passageObservedAt = iso(121);
    expect(project(before).state.phase).toBe("underway");
  });

  it("confirms passage beyond a selected intermediate destination, including an older arrival report", () => {
    const value = trip(position(-3.85));
    expect(project(value, value.stops[1]!.stationId).state.phase).toBe("ended");
    value.stops[1]!.arrivalObservedAt = iso(-120);
    expect(project(value, value.stops[1]!.stationId).state.phase).toBe("ended");
  });

  it("ignores stale or inferred GPS and rejects off-route and ambiguous-loop projection", () => {
    expect(project(trip(position(-3.98, -301))).state.phase).toBe("unavailable");
    expect(project(trip({ ...position(), source: "inferred" })).state.phase).toBe("unavailable");
    const offRoute = trip(position(-2));
    expect(routePositionEvidence(offRoute, offRoute.stops, offRoute.positions![0]!)).toBeNull();
    const loop = trip();
    loop.stops[2]!.longitude = -4;
    expect(routePositionEvidence(loop, loop.stops, loop.positions![0]!)).toBeNull();
    expect(project(loop).shouldEnd).toBe(false);
  });

  it("uses encoded route geometry at supported precision instead of a straight station chord", () => {
    const coordinates = [{ latitude: 40, longitude: -4 }, { latitude: 40.03, longitude: -3.95 },
      { latitude: 40, longitude: -3.9 }, { latitude: 40, longitude: -3.8 }];
    for (const precision of [5, 6, 7]) {
      const factor = 10 ** (precision - 5);
      const value = trip({ ...position(-3.95), latitude: 40.03 });
      value.routeGeometry = { source: "Transitous", segments: [{ precision, pointCount: coordinates.length,
        encodedPolyline: encodePolyline5(coordinates.map((point) => ({
          latitude: point.latitude * factor, longitude: point.longitude * factor,
        }))) }] };
      expect(project(value).state.focusName).toBe("Middle");
      expect(routePositionEvidence(value, value.stops, value.positions![0]!)?.arrived).toBe(false);
    }
  });

  it("does not advance an explicit arrival-only dwell because of an old unstamped passed flag", () => {
    const value = trip(position(-3.98, -301));
    value.stops[1]!.passed = true;
    value.stops[1]!.arrivalObservedAt = iso(-60);
    const result = project(value);
    expect(result.state.phase).toBe("underway");
    expect(result.state.focusName).toBe("Middle");
  });
});
