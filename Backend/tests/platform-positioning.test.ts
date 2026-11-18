import { describe, expect, it } from "vitest";
import {
  positionPlatformForecast,
  productionPlatformForecastReleasePolicy,
  productionStationPlatformGeographies,
  type PlatformForecastReleasePolicy,
  type StationPlatformGeography,
} from "../src/domain/platform-positioning.js";
import type { HistoricalPlatformForecast, PlatformForecastRequest } from "../src/domain/platform-forecast.js";

const geography: StationPlatformGeography = {
  stationId: "station:central",
  version: "central-map-v1",
  verifiedAt: "2026-07-01T00:00:00.000Z",
  validUntil: "2027-07-01T00:00:00.000Z",
  neutralZoneId: "main-hall",
  zones: [
    { id: "east", label: "east concourse", platforms: ["8", "9"] },
    { id: "west", label: "west concourse", platforms: ["10", "11"] },
    { id: "main-hall", label: "main hall", platforms: ["8", "9", "10", "11"] },
  ],
  harmfulZonePairs: [{ recommendedZoneId: "east", actualZoneId: "west" }],
};

const qualifiedPolicy: PlatformForecastReleasePolicy = {
  globalDisplayEnabled: true,
  disabledSources: [],
  disabledStations: [],
  qualifiedCohorts: [{
    stationId: "station:central",
    sourceName: "DB Timetables",
    serviceFamily: "ICE",
    eventType: "departure",
    horizon: "1h-to-6h",
    correctZoneRate: 0.94,
    exactPrecision: 0.88,
    harmfulDisplacementRate: 0.01,
    exactDisplayEnabled: true,
  }],
};

function request(overrides: Partial<PlatformForecastRequest> = {}): PlatformForecastRequest {
  return {
    eventId: "event-1",
    stationId: "station:central",
    sourceName: "DB Timetables",
    operatorName: "DB Fernverkehr AG",
    product: "ICE 742",
    headsign: "Münster Hbf",
    routeSignature: "route-v1",
    eventType: "departure",
    serviceDate: "2026-08-01",
    scheduledTime: "2026-08-01T12:00:00.000Z",
    generatedAt: "2026-08-01T08:00:00.000Z",
    officialPlatform: null,
    ...overrides,
  };
}

function historical(
  candidates: HistoricalPlatformForecast["candidates"],
  overrides: Partial<HistoricalPlatformForecast> = {},
): HistoricalPlatformForecast {
  return {
    kind: "forecast",
    cohort: "weekday-time-route",
    evidenceCount: 30,
    strictEvidenceCount: 20,
    candidates,
    likelyPlatform: candidates[0]!.platform,
    confidence: candidates[0]!.probability >= 0.85 ? "high" : "medium",
    horizon: "1h-to-6h",
    timetablePeriod: "2025-2026",
    modelVersion: "historical-bayes-v1",
    generatedAt: "2026-08-01T08:00:00.000Z",
    expiresAt: "2026-08-01T08:30:00.000Z",
    explanation: "30 completed comparable services in 2025-2026.",
    ...overrides,
  };
}

describe("platform positioning", () => {
  it("keeps the production station and release catalogs default-deny", () => {
    expect(productionStationPlatformGeographies).toEqual([]);
    expect(productionPlatformForecastReleasePolicy).toMatchObject({
      globalDisplayEnabled: false,
      qualifiedCohorts: [],
    });
  });

  it("selects the narrowest verified zone containing ninety percent of probability", () => {
    const result = positionPlatformForecast({
      request: request(),
      historical: historical([
        { platform: "8", probability: 0.6, observationCount: 18 },
        { platform: "9", probability: 0.3, observationCount: 9 },
        { platform: "10", probability: 0.1, observationCount: 3 },
      ]),
      geography,
      policy: qualifiedPolicy,
      now: "2026-08-01T08:05:00.000Z",
    });

    expect(result).toMatchObject({
      kind: "forecast",
      state: "positioning",
      zone: {
        id: "east",
        label: "east concourse",
        platforms: ["8", "9"],
        probability: 0.9,
      },
      likelyPlatform: null,
      stationMapVersion: "central-map-v1",
    });
  });

  it("shows an exact likely platform only when probability and cohort precision qualify", () => {
    const result = positionPlatformForecast({
      request: request(),
      historical: historical([
        { platform: "8", probability: 0.87, observationCount: 27 },
        { platform: "9", probability: 0.13, observationCount: 3 },
      ]),
      geography,
      policy: qualifiedPolicy,
      now: "2026-08-01T08:05:00.000Z",
    });

    expect(result).toMatchObject({
      kind: "forecast",
      state: "likely-platform",
      likelyPlatform: "8",
      confidence: "high",
      zone: { id: "east", probability: 1 },
    });
  });

  it("does not infer geography from a numeric platform label", () => {
    const result = positionPlatformForecast({
      request: request(),
      historical: historical([
        { platform: "7", probability: 0.9, observationCount: 27 },
        { platform: "8", probability: 0.1, observationCount: 3 },
      ]),
      geography,
      policy: qualifiedPolicy,
      now: "2026-08-01T08:05:00.000Z",
    });
    expect(result).toEqual({ kind: "abstention", reason: "platform-not-mapped" });
  });

  it("honors global, source, station, map freshness, and expiry gates", () => {
    const value = historical([
      { platform: "8", probability: 0.9, observationCount: 27 },
      { platform: "9", probability: 0.1, observationCount: 3 },
    ]);
    const disabledGlobal = { ...qualifiedPolicy, globalDisplayEnabled: false };
    const disabledSource = { ...qualifiedPolicy, disabledSources: ["DB Timetables"] };
    const disabledStation = { ...qualifiedPolicy, disabledStations: ["station:central"] };
    for (const policy of [disabledGlobal, disabledSource, disabledStation]) {
      expect(positionPlatformForecast({
        request: request(), historical: value, geography, policy, now: "2026-08-01T08:05:00.000Z",
      })).toEqual({ kind: "abstention", reason: "release-disabled" });
    }
    expect(positionPlatformForecast({
      request: request(), historical: value,
      geography: { ...geography, validUntil: "2026-07-31T23:59:59.000Z" },
      policy: qualifiedPolicy, now: "2026-08-01T08:05:00.000Z",
    })).toEqual({ kind: "abstention", reason: "station-map-expired" });
    expect(positionPlatformForecast({
      request: request(), historical: value, geography, policy: qualifiedPolicy,
      now: "2026-08-01T08:30:00.000Z",
    })).toEqual({ kind: "abstention", reason: "forecast-expired" });
  });

  it("requires customer evidence and independently qualified cohort metrics", () => {
    const candidates = [{ platform: "8", probability: 1, observationCount: 29 }];
    expect(positionPlatformForecast({
      request: request(), historical: historical(candidates, { evidenceCount: 29 }),
      geography, policy: qualifiedPolicy, now: "2026-08-01T08:05:00.000Z",
    })).toEqual({ kind: "abstention", reason: "insufficient-customer-history" });
    expect(positionPlatformForecast({
      request: request(), historical: historical(candidates, { evidenceCount: 30 }),
      geography, policy: { ...qualifiedPolicy, qualifiedCohorts: [] },
      now: "2026-08-01T08:05:00.000Z",
    })).toEqual({ kind: "abstention", reason: "cohort-unqualified" });
  });
});
