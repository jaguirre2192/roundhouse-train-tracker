import { describe, expect, it } from "vitest";
import type { StopSnapshot, TripSnapshot } from "../src/domain/snapshot.js";
import { hasReportedArrival, hasReportedPassage } from "../src/domain/stop-passage.js";
import { AmtrakerProvider } from "../src/providers/amtraker.js";
import { TransitousProvider } from "../src/providers/transitous.js";
import { TripSnapshotEnricher } from "../src/providers/platform-overlay.js";
import { realtimeCandidateStops } from "../src/providers/realtime-stop-candidates.js";

const now = "2026-11-13T12:00:00Z";

function stop(overrides: Partial<StopSnapshot> = {}): StopSnapshot {
  return { stationId: "eu:transitous:es-madrid", stationName: "Madrid", countryCode: "ES",
    latitude: 40.4, longitude: -3.7, sequence: 1, scheduledArrival: null,
    scheduledDeparture: "2026-11-13T10:00:00Z", expectedArrival: null,
    expectedDeparture: "2026-11-13T10:00:00Z", plannedPlatform: null, expectedPlatform: null,
    platformSource: null, platformObservedAt: null, cancelled: false, passed: false, ...overrides };
}

function snapshot(stops = [stop()]): TripSnapshot {
  return { id: "eu:transitous:es-renfe-123", source: "transitous", nativeId: "es-renfe-123",
    serviceDate: "2026-11-13", operatorName: "Renfe", product: "AVE 123", headsign: "Barcelona",
    fetchedAt: now, stops, alertIds: [] };
}

describe("Reported stop passage", () => {
  it("does not turn elapsed Spanish timetable fields into passed stops", async () => {
    const place = { name: "Madrid", stopId: "es-madrid", country: "ES", lat: 40.4, lon: -3.7,
      scheduledDeparture: "2026-11-13T10:00:00Z", departure: "2026-11-13T10:00:00Z" };
    const provider = new TransitousProvider("https://example.test", async () => Response.json({ legs: [{
      mode: "LONG_DISTANCE", tripId: "es-renfe-123", agencyName: "Renfe",
      from: place, to: { ...place, name: "Barcelona", stopId: "es-barcelona", lat: 41.4, lon: 2.1 },
    }] }), () => new Date(now));
    const result = await provider.fetchTrip(snapshot());
    expect(result.stops).toHaveLength(2);
    expect(result.stops.every((call) => !call.passed && call.passageObservedAt === undefined)).toBe(true);
  });

  it("distinguishes reported departure from arrival and terminal dwell", async () => {
    const provider = new AmtrakerProvider("https://example.test", async (input) =>
      Response.json(String(input).endsWith("/stations") ? {} : { "7": [{
        trainID: "7-13", trainNum: "7", routeName: "Test train", stations: [
          { code: "A", name: "A", schDep: "2026-11-13T10:00:00Z", dep: "2026-11-13T10:15:00Z", status: "Departed" },
          { code: "B", name: "B", schArr: "2026-11-13T11:00:00Z", arr: "2026-11-13T11:10:00Z", status: "Arrived" },
          { code: "C", name: "C", schArr: "2026-11-13T12:00:00Z", arr: now, status: "Arrived" },
        ],
      }] }), () => new Date(now));
    const result = await provider.fetchTrip({ id: "us:amtraker:7-13", source: "amtraker",
      nativeId: "7-13", serviceDate: "2026-11-13" });
    expect(hasReportedPassage(result.stops[0]!, now)).toBe(true);
    expect(hasReportedPassage(result.stops[1]!, now)).toBe(false);
    expect(hasReportedArrival(result.stops[1]!, now)).toBe(true);
    expect(hasReportedArrival(result.stops[2]!, now)).toBe(true);
    expect(result.stops[0]!.passageObservedAt).toBe("2026-11-13T10:15:00.000Z");
  });

  it("does not renew old event or source observations when an unchanged feed is fetched again", async () => {
    let clock = new Date(now);
    const provider = new AmtrakerProvider("https://example.test", async (input) =>
      Response.json(String(input).endsWith("/stations") ? {} : { "7": [{
        trainID: "7-13", trainNum: "7", routeName: "Test train", lastValTS: "2026-11-13T09:00:00Z", stations: [
          { code: "A", name: "A", schDep: "2026-11-13T08:00:00Z", dep: "2026-11-13T08:15:00Z", status: "Departed" },
          { code: "B", name: "B", schArr: "2026-11-13T08:30:00Z", status: "Arrived" },
        ],
      }] }), () => clock);
    const reference = { id: "us:amtraker:7-13", source: "amtraker" as const,
      nativeId: "7-13", serviceDate: "2026-11-13" };
    const first = await provider.fetchTrip(reference);
    clock = new Date("2026-11-13T13:00:00Z");
    const second = await provider.fetchTrip(reference);
    expect(first.fetchedAt).not.toBe(second.fetchedAt);
    expect(first.stops).toEqual(second.stops);
    expect(second.stops[0]!.passageObservedAt).toBe("2026-11-13T08:15:00.000Z");
    expect(second.stops[1]!.arrivalObservedAt).toBe("2026-11-13T09:00:00.000Z");
  });

  it("does not let an overlay timestamp manufacture passage or erase an actual departure", async () => {
    const enricher = new TripSnapshotEnricher([{
      sourceName: "Renfe", supportedCountryCodes: new Set(["ES"]), platformUpdates: async () => [{
        stopSequence: 1, stationId: "eu:transitous:es-madrid", expectedDeparture: "2026-11-13T11:00:00Z",
        expectedPlatform: "4", observedAt: now, source: "Renfe",
      }],
    }]);
    const guessed = await enricher.enrich(snapshot([stop({ passed: true })]));
    expect(guessed.stops[0]!.passed).toBe(false);
    const reported = await enricher.enrich(snapshot([stop({ passed: true, passageObservedAt: now })]));
    expect(hasReportedPassage(reported.stops[0]!, now)).toBe(true);
  });

  it("selects near-now overlay calls without relying on guessed passed flags", () => {
    const calls = [6, 7, 8, 9, 10, 11, 12, 13].map((hour, index) => stop({
      stationId: String(hour), sequence: index + 1,
      scheduledDeparture: `2026-11-13T${String(hour).padStart(2, "0")}:00:00Z`,
      expectedDeparture: null, passed: false,
    }));
    expect(realtimeCandidateStops(snapshot(calls), () => true, 1).map((call) => call.stationId)).toEqual(["11", "12"]);
  });

  it("rejects unstamped flags, malformed observations, and future reports", () => {
    for (const passageObservedAt of [undefined, "invalid", "2026-11-13T12:02:01Z"]) {
      const call = stop({ passed: true, ...(passageObservedAt === undefined ? {} : { passageObservedAt }) });
      expect(hasReportedPassage(call, now)).toBe(false);
      expect(hasReportedArrival(call, now)).toBe(false);
    }
    expect(hasReportedArrival(stop({ arrivalObservedAt: "2026-11-13T12:02:01Z" }), now)).toBe(false);
  });
});
