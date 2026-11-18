import { describe, expect, it } from "vitest";
import { runTemporalPlatformBacktest } from "../src/domain/platform-backtest.js";
import type { HistoricalPlatformObservation } from "../src/domain/platform-forecast.js";
import type { StationPlatformGeography } from "../src/domain/platform-positioning.js";

const geography: StationPlatformGeography = {
  stationId: "station:central",
  version: "central-map-v1",
  verifiedAt: "2026-01-01T00:00:00.000Z",
  validUntil: "2027-01-01T00:00:00.000Z",
  neutralZoneId: "hall",
  zones: [
    { id: "east", label: "east concourse", platforms: ["8", "9"] },
    { id: "west", label: "west concourse", platforms: ["10", "11"] },
    { id: "hall", label: "main hall", platforms: ["8", "9", "10", "11"] },
  ],
  harmfulZonePairs: [{ recommendedZoneId: "east", actualZoneId: "west" }],
};

function observation(index: number, platform: string): HistoricalPlatformObservation {
  const date = new Date(Date.UTC(2026, 0, index + 1, 12));
  const serviceDate = date.toISOString().slice(0, 10);
  return {
    eventId: `event-${index}`,
    stationId: "station:central",
    sourceName: "DB Timetables",
    operatorName: "DB Fernverkehr AG",
    product: "ICE 742",
    headsign: "Münster Hbf",
    routeSignature: "route-v1",
    eventType: "departure",
    serviceDate,
    scheduledTime: `${serviceDate}T12:00:00.000Z`,
    effectivePlatform: platform,
    finalObservedAt: `${serviceDate}T12:05:00.000Z`,
  };
}

describe("temporal platform backtest", () => {
  it("uses only ground truth available before each prediction", () => {
    const observations = Array.from({ length: 12 }, (_, index) => observation(index, index < 10 ? "8" : "10"));
    const report = runTemporalPlatformBacktest(observations, {
      geography,
      leadTimeMilliseconds: 2 * 60 * 60_000,
    });

    expect(report.horizon).toBe("1h-to-6h");
    expect(report.evaluations[0]).toMatchObject({
      eventId: "event-5",
      evidenceCount: 5,
      likelyPlatform: "8",
    });
    expect(report.evaluations.at(-1)).toMatchObject({
      eventId: "event-11",
      evidenceCount: 11,
      actualPlatform: "10",
    });
  });

  it("reports literal zone, exact, harmful-displacement, calibration, and abstention metrics", () => {
    const observations = [
      ...Array.from({ length: 10 }, (_, index) => observation(index, "8")),
      observation(10, "10"),
      observation(11, "8"),
    ];
    const report = runTemporalPlatformBacktest(observations, {
      geography,
      leadTimeMilliseconds: 2 * 60 * 60_000,
    });

    expect(report).toMatchObject({
      totalEvents: 12,
      evaluatedForecasts: 7,
      abstentions: { "insufficient-history": 5 },
      correctZoneCount: 6,
      positioningForecastCount: 7,
      exactDisplayedCount: 7,
      exactCorrectCount: 6,
      harmfulDisplacementCount: 1,
      correctZoneRate: 0.857143,
      exactPrecision: 0.857143,
      harmfulDisplacementRate: 0.142857,
    });
    expect(report.meanAbsoluteCalibrationError).toBeGreaterThan(0);
    expect(report.meanAbsoluteCalibrationError).toBeLessThan(1);
  });
});
