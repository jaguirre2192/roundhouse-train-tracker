import { describe, expect, it, vi } from "vitest";
import {
  parseSharedTrip, parseStationBoardRequest, parseSubscription, parseTripSnapshotRequest,
} from "../src/cloudflare/api-validation.js";
import type { WatcherRepository } from "../src/db/repository.js";
import type { JourneyCallSnapshot, JourneyOptionSnapshot } from "../src/domain/journey.js";
import { createJourneyTrackingToken, resolveJourneyTrackingToken } from "../src/domain/journey-tokens.js";
import type { CanonicalTripReference, TripSnapshot } from "../src/domain/snapshot.js";
import { makeApp } from "../src/http/app.js";
import { ProviderRegistry, type RailProvider } from "../src/providers/provider.js";
import { encodeRailPlaceId } from "../src/providers/rail-place-id.js";

const now = new Date("2026-11-13T09:00:00Z");
const secret = "test-serbian-tracking-and-sharing-secret";
const trip: CanonicalTripReference = {
  id: "rs:srbijavoz:fixture-train:2026-11-13", source: "srbijavoz",
  nativeId: "fixture-train:2026-11-13", serviceDate: "2026-11-13",
};
const stationId = (nativeId: string) => encodeRailPlaceId({
  provider: "srbijavoz", kind: "station", nativeId, countryCode: "RS", latitude: null, longitude: null,
});
const origin = stationId("fixture-origin");
const destination = stationId("fixture-destination");
const subscription = {
  installationId: "ba141c63-e992-48ed-8c46-86cb6d42586a", trip,
  boardingStationId: origin, alightingStationId: destination, watchFrom: now.toISOString(),
};
const board = {
  stationId: "rs:srbijavoz:fixture-origin", nativeId: "fixture-origin", source: "srbijavoz",
  at: now.toISOString(), direction: "departures",
};

function call(id: string, time: string, position: "from" | "to"): JourneyCallSnapshot {
  return {
    place: {
      id, kind: "station", displayName: "Fixture station", context: "Serbia", countryCode: "RS",
      timeZoneIdentifier: "Europe/Belgrade", location: { latitude: 44.8, longitude: 20.4 },
      eligibleModes: ["regionalRail"], attributions: ["Fixture provider"],
    },
    city: null, scheduledArrival: position === "to" ? time : null,
    scheduledDeparture: position === "from" ? time : null,
    expectedArrival: position === "to" ? time : null, expectedDeparture: position === "from" ? time : null,
    plannedPlatform: null, expectedPlatform: null, isCancelled: false,
  };
}

function option(id = trip.id): JourneyOptionSnapshot {
  return {
    id: "fixture-option", fingerprint: "journey-v1-serbian-fixture", startTime: "2026-11-13T10:00:00Z",
    endTime: "2026-11-13T11:00:00Z", duration: 3600, transferCount: 0,
    segments: [{
      id: "fixture-segment", kind: "rail", walk: null,
      rail: {
        tripId: id, serviceDate: trip.serviceDate, operatorName: "Fixture provider", product: "Regional",
        trainNumber: "123", trainName: null, from: call(origin, "2026-11-13T10:00:00Z", "from"),
        to: call(destination, "2026-11-13T11:00:00Z", "to"), intermediateCalls: [],
        isCancelled: false, isRealtime: false, isTrackable: true, untrackableReason: null,
      },
    }],
    badges: ["direct"], trackability: { trackableRailSegments: 1, totalRailSegments: 1 },
    realtimeFreshness: null, attributions: ["Fixture provider"], trackingToken: "",
  };
}

describe("Serbian source contracts", () => {
  it("signs and resolves the canonical trip and exact Serbian station identities", () => {
    const signed = createJourneyTrackingToken(option(), secret, now);
    const resolved = resolveJourneyTrackingToken(signed.token, secret, now);
    expect(resolved).toMatchObject({
      originStationId: origin, destinationStationId: destination,
      railSegments: [{ segmentId: "fixture-segment", trip, boardingStationId: origin, alightingStationId: destination }],
    });
    expect(() => resolveJourneyTrackingToken(signed.token, "different-secret", now)).toThrow("Invalid journey tracking token");
  });

  it.each(["eu", "RS", "other"])("rejects a Serbian trip in the noncanonical %s namespace", (prefix) => {
    expect(() => createJourneyTrackingToken(option(`${prefix}:srbijavoz:${trip.nativeId}`), secret, now))
      .toThrow("Invalid journey tracking input");
  });

  it("accepts Serbian snapshots, boards, shares, and subscriptions in Cloudflare validation", () => {
    expect(parseTripSnapshotRequest(new URLSearchParams({ ...trip }))).toEqual(trip);
    expect(parseStationBoardRequest(new URLSearchParams(board))).toMatchObject({ ...board, at: "2026-11-13T09:00:00Z" });
    expect(parseSharedTrip({ trip, boardingStationId: origin, alightingStationId: destination })).toEqual({
      trip, boardingStationId: origin, alightingStationId: destination,
    });
    expect(parseSubscription(subscription)).toMatchObject(subscription);
  });

  it.each(["amtraker", "transitous", "ekispert", "tdx", "chepe"])(
    "preserves the existing public %s source allowlists", (source) => {
      expect(parseTripSnapshotRequest(new URLSearchParams({ ...trip, source })).source).toBe(source);
      expect(parseStationBoardRequest(new URLSearchParams({ ...board, source })).source).toBe(source);
      expect(parseSharedTrip({ trip: { ...trip, source } }).trip.source).toBe(source);
      expect(parseSubscription({ ...subscription, trip: { ...trip, source } }).trip.source).toBe(source);
    },
  );

  it("continues rejecting unknown sources in each Cloudflare allowlist", () => {
    const source = "unsupported";
    expect(() => parseTripSnapshotRequest(new URLSearchParams({ ...trip, source }))).toThrow("Invalid request");
    expect(() => parseStationBoardRequest(new URLSearchParams({ ...board, source }))).toThrow("Invalid request");
    expect(() => parseSharedTrip({ trip: { ...trip, source } })).toThrow("Invalid request");
    expect(() => parseSubscription({ ...subscription, trip: { ...trip, source } })).toThrow("Invalid request");
  });

  it("accepts the new source through self-hosted API validators and signed share resolution", async () => {
    const snapshot: TripSnapshot = {
      ...trip, operatorName: "Fixture provider", product: "Regional", headsign: "Fixture destination",
      fetchedAt: now.toISOString(), stops: [], alertIds: [],
    };
    const provider: RailProvider = {
      source: "srbijavoz", discoveryScope: "international", searchStations: vi.fn().mockResolvedValue([]),
      fetchBoard: vi.fn().mockResolvedValue([]), fetchTrip: vi.fn().mockResolvedValue(snapshot),
    };
    const repository = {
      recordPlatformObservations: vi.fn().mockResolvedValue(undefined),
      forecastPlatformSnapshot: vi.fn().mockResolvedValue(snapshot), subscribe: vi.fn().mockResolvedValue("allowed"),
    } as unknown as WatcherRepository;
    const app = makeApp(repository, new ProviderRegistry([provider]), "silent", secret);
    try {
      const response = await app.inject({ method: "GET", url: `/v1/trips/snapshot?${new URLSearchParams({ ...trip })}` });
      expect(response.statusCode).toBe(200);
      expect(response.json()).toEqual(snapshot);
      expect(provider.fetchTrip).toHaveBeenCalledWith(trip);
      const boardResponse = await app.inject({ method: "GET", url: `/v1/stations/board?${new URLSearchParams(board)}` });
      expect(boardResponse.statusCode).toBe(200);
      expect(provider.fetchBoard).toHaveBeenCalledWith(board);
      const shared = await app.inject({ method: "POST", url: "/v1/shares", payload: { trip } });
      expect(shared.statusCode).toBe(201);
      const sharedToken = (shared.json() as { url: string }).url.split("/s/")[1]!;
      expect(sharedToken.length).toBeGreaterThan(100);
      const resolved = await app.inject({ method: "GET", url: `/v1/shares/${sharedToken}` });
      expect(resolved.statusCode).toBe(200);
      expect(resolved.json()).toMatchObject({ trip });
      const subscribed = await app.inject({
        method: "POST", url: "/v1/subscriptions", payload: subscription,
        headers: { authorization: `Device ${"d".repeat(43)}` },
      });
      expect(subscribed.statusCode).toBe(204);
      expect(repository.subscribe).toHaveBeenCalledWith(expect.objectContaining({ trip }), expect.any(String));
    } finally { await app.close(); }
  });

  it("allows the declared share-token boundary while rejecting oversized route parameters", async () => {
    const app = makeApp({} as WatcherRepository, new ProviderRegistry([]), "silent", secret);
    try {
      const invalidAtLimit = await app.inject({ method: "GET", url: `/v1/shares/${"a".repeat(4_000)}` });
      expect(invalidAtLimit.statusCode).toBe(404);
      expect(invalidAtLimit.json()).toEqual({ error: "share_not_found" });
      const oversized = await app.inject({ method: "GET", url: `/v1/shares/${"a".repeat(4_001)}` });
      expect(oversized.statusCode).toBe(414);
    } finally { await app.close(); }
  });
});
