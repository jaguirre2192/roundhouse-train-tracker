import { describe, expect, it } from "vitest";
import {
  platformObservationPolicy,
  predictionMarket,
  projectPlatformObservations,
  routeSignature,
} from "../src/domain/platform-observation.js";
import type { StopSnapshot, TripSnapshot } from "../src/domain/snapshot.js";

function stop(overrides: Partial<StopSnapshot> = {}): StopSnapshot {
  return {
    stationId: "eu:transitous:berlin-hbf",
    stationName: "Berlin Hbf",
    countryCode: "DE",
    latitude: 52.525,
    longitude: 13.369,
    sequence: 1,
    scheduledArrival: "2026-07-21T16:12:00.000Z",
    scheduledDeparture: "2026-07-21T16:16:00.000Z",
    expectedArrival: "2026-07-21T16:12:00.000Z",
    expectedDeparture: "2026-07-21T16:21:00.000Z",
    plannedPlatform: "8",
    expectedPlatform: "11",
    platformSource: "DB Timetables",
    platformObservedAt: "2026-07-21T16:10:00.000Z",
    cancelled: false,
    passed: false,
    ...overrides,
  };
}

function trip(overrides: Partial<TripSnapshot> = {}): TripSnapshot {
  return {
    id: "eu:transitous:ice-742",
    source: "transitous",
    nativeId: "ice-742",
    serviceDate: "2026-07-21",
    operatorName: "DB Fernverkehr AG",
    product: "ICE 742",
    headsign: "Münster Hbf",
    fetchedAt: "2026-07-21T16:10:05.000Z",
    stops: [
      stop(),
      stop({
        stationId: "eu:transitous:hannover-hbf",
        stationName: "Hannover Hbf",
        sequence: 2,
        scheduledArrival: "2026-07-21T17:45:00.000Z",
        scheduledDeparture: "2026-07-21T17:48:00.000Z",
        plannedPlatform: null,
        expectedPlatform: null,
        platformSource: null,
        platformObservedAt: null,
      }),
    ],
    alertIds: [],
    ...overrides,
  };
}

function delfiTrip(overrides: Partial<TripSnapshot> = {}): TripSnapshot {
  return trip({
    nativeId: "20260721_16:16_de-DELFI_ice-742",
    ...overrides,
  });
}

describe("platform observation projection", () => {
  it("classifies the two launch markets and excludes countries outside them", () => {
    expect(predictionMarket("DE")).toBe("western-europe");
    expect(predictionMarket("gb")).toBe("western-europe");
    expect(predictionMarket("US")).toBe("north-america");
    expect(predictionMarket("ca")).toBe("north-america");
    expect(predictionMarket("JP")).toBeNull();
  });

  it("is default-deny while enabling sources with recorded publication and retention rights", () => {
    expect(platformObservationPolicy("DB Timetables")).toMatchObject({
      status: "enabled",
      license: "CC BY 4.0",
      attribution: "Deutsche Bahn AG",
    });
    expect(platformObservationPolicy("Translink NI Opendata API")).toMatchObject({
      status: "enabled",
      license: "Translink Transport Data API Licence and User Agreement",
      attribution: "Transport Information supplied by Translink Opendata API",
    });
    expect(platformObservationPolicy("Amtraker")).toEqual({
      sourceName: "Amtraker",
      status: "review-required",
      license: null,
      attribution: null,
      evidenceURL: null,
      reason: "No feed-specific retention basis has been recorded.",
    });
  });

  it("projects an attributed operational observation with stable state identity", () => {
    const first = projectPlatformObservations(trip(), "snapshot");
    const later = projectPlatformObservations(trip({ fetchedAt: "2026-07-21T16:10:25.000Z" }), "watcher");

    expect(first.skipped).toEqual([]);
    expect(first.observations).toHaveLength(1);
    expect(first.observations[0]).toMatchObject({
      market: "western-europe",
      countryCode: "DE",
      sourceName: "DB Timetables",
      sourceLicense: "CC BY 4.0",
      sourceAttribution: "Deutsche Bahn AG",
      tripSource: "transitous",
      nativeTripId: "ice-742",
      stationId: "eu:transitous:berlin-hbf",
      callType: "arrival-departure",
      plannedPlatform: "8",
      expectedPlatform: "11",
      effectivePlatform: "11",
      collectionTrigger: "snapshot",
      firstObservedAt: "2026-07-21T16:10:05.000Z",
      lastObservedAt: "2026-07-21T16:10:05.000Z",
      sampleCount: 1,
    });
    expect(later.observations[0]?.fingerprint).toBe(first.observations[0]?.fingerprint);
    expect(later.observations[0]?.routeSignature).toBe(first.observations[0]?.routeSignature);
  });

  it("changes the fingerprint when the effective platform changes", () => {
    const original = projectPlatformObservations(trip(), "snapshot").observations[0];
    const changed = projectPlatformObservations(trip({
      stops: [stop({ expectedPlatform: "12" })],
    }), "snapshot").observations[0];

    expect(changed?.fingerprint).not.toBe(original?.fingerprint);
  });

  it("builds route identity from ordered station IDs rather than fetch time", () => {
    const snapshot = trip();
    expect(routeSignature(snapshot)).toBe(routeSignature({ ...snapshot, fetchedAt: "2030-01-01T00:00:00.000Z" }));
    expect(routeSignature(snapshot)).not.toBe(routeSignature({ ...snapshot, stops: [...snapshot.stops].reverse() }));
  });

  it("does not retain unapproved sources, platform-less stops, or out-of-market stops", () => {
    const result = projectPlatformObservations(trip({
      stops: [
        stop({ platformSource: "Amtraker", countryCode: "US" }),
        stop({ stationId: "us:amtraker:PHL", countryCode: "US", plannedPlatform: null, expectedPlatform: null }),
        stop({ stationId: "jp:station:tokyo", countryCode: "JP" }),
      ],
    }), "snapshot");

    expect(result.observations).toEqual([]);
    expect(result.skipped).toEqual([
      expect.objectContaining({
        stationId: "eu:transitous:berlin-hbf",
        sourceName: "Amtraker",
        reason: "No feed-specific retention basis has been recorded.",
      }),
    ]);
  });

  it("keeps the canonical payload operational and rider-free", () => {
    const observation = projectPlatformObservations(trip(), "snapshot").observations[0]!;
    const json = JSON.stringify(observation.payload);

    expect(observation.payload).toMatchObject({
      trip: {
        source: "transitous",
        nativeId: "ice-742",
        serviceDate: "2026-07-21",
      },
      stop: {
        stationId: "eu:transitous:berlin-hbf",
        effectivePlatform: "11",
      },
      provenance: {
        sourceName: "DB Timetables",
        license: "CC BY 4.0",
      },
    });
    for (const forbidden of ["installationId", "accountId", "passenger", "ticket", "coach", "seat", "pushToken"]) {
      expect(json).not.toContain(forbidden);
    }
  });

  it("records DELFI schedule provenance and excludes mixed-source expected times", () => {
    const observation = projectPlatformObservations(delfiTrip(), "watcher").observations[0]!;

    expect(observation).toMatchObject({
      expectedArrival: null,
      expectedDeparture: null,
      payload: {
        stop: {
          expectedArrival: null,
          expectedDeparture: null,
        },
        provenance: {
          sourceName: "DB Timetables",
          schedule: {
            sourceName: "DELFI",
            license: "CC BY 4.0",
            attribution: "DELFI e.V.",
            evidenceURL: "https://transitous.org/sources/",
          },
        },
      },
    });
  });
});
