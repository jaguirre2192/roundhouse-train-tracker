import { describe, expect, it } from "vitest";
import {
  historicalPlatformForecast,
  predictionHorizon,
  railwayTimetablePeriod,
  serviceFamily,
  type HistoricalPlatformObservation,
  type PlatformForecastRequest,
} from "../src/domain/platform-forecast.js";

const generatedAt = "2026-08-01T08:00:00.000+02:00";

function request(overrides: Partial<PlatformForecastRequest> = {}): PlatformForecastRequest {
  return {
    eventId: "current-ice-742-berlin-departure",
    stationId: "eu:transitous:berlin-hbf",
    sourceName: "DB Timetables",
    operatorName: "DB Fernverkehr AG",
    product: "ICE 742",
    headsign: "Münster Hbf",
    routeSignature: "route-v1-berlin-hannover-munster",
    eventType: "departure",
    serviceDate: "2026-08-01",
    scheduledTime: "2026-08-01T16:00:00.000+02:00",
    generatedAt,
    officialPlatform: null,
    ...overrides,
  };
}

function history(
  index: number,
  platform: string,
  overrides: Partial<HistoricalPlatformObservation> = {},
): HistoricalPlatformObservation {
  const day = String(index + 1).padStart(2, "0");
  return {
    eventId: `historical-ice-742-${day}`,
    stationId: "eu:transitous:berlin-hbf",
    sourceName: "DB Timetables",
    operatorName: "DB Fernverkehr AG",
    product: "ICE 742",
    headsign: "Münster Hbf",
    routeSignature: "route-v1-berlin-hannover-munster",
    eventType: "departure",
    serviceDate: `2026-07-${day}`,
    scheduledTime: `2026-07-${day}T16:00:00.000+02:00`,
    effectivePlatform: platform,
    finalObservedAt: `2026-07-${day}T16:05:00.000+02:00`,
    ...overrides,
  };
}

describe("historical platform forecast", () => {
  it("uses stable horizon boundaries", () => {
    expect(predictionHorizon("2026-08-02T08:00:00.000Z", "2026-08-01T08:00:00.000Z")).toBe("24h-plus");
    expect(predictionHorizon("2026-08-01T14:00:00.000Z", "2026-08-01T08:00:00.000Z")).toBe("6h-to-24h");
    expect(predictionHorizon("2026-08-01T09:00:00.000Z", "2026-08-01T08:00:00.000Z")).toBe("1h-to-6h");
    expect(predictionHorizon("2026-08-01T08:15:00.000Z", "2026-08-01T08:00:00.000Z")).toBe("15m-to-1h");
    expect(predictionHorizon("2026-08-01T08:14:59.000Z", "2026-08-01T08:00:00.000Z")).toBe("under-15m");
  });

  it("normalizes a numbered service into an explainable service family", () => {
    expect(serviceFamily(" ICE 742 ")).toBe("ICE");
    expect(serviceFamily("Northeast Regional 171")).toBe("NORTHEAST REGIONAL");
    expect(serviceFamily("RE 1 (4401)")).toBe("RE");
  });

  it("separates observations across the annual railway timetable boundary", () => {
    expect(railwayTimetablePeriod("2026-12-12")).toBe("2025-2026");
    expect(railwayTimetablePeriod("2026-12-13")).toBe("2026-2027");
  });

  it("abstains when an official platform already exists or the event has passed", () => {
    expect(historicalPlatformForecast(request({ officialPlatform: "8" }), [])).toEqual({
      kind: "abstention",
      reason: "official-platform-available",
    });
    expect(historicalPlatformForecast(request({
      scheduledTime: "2026-08-01T07:59:00.000+02:00",
    }), [])).toEqual({ kind: "abstention", reason: "event-passed" });
  });

  it("requires five completed comparable services for a shadow forecast", () => {
    const result = historicalPlatformForecast(request(), [
      history(0, "8"), history(1, "8"), history(2, "9"), history(3, "8"),
    ]);
    expect(result).toEqual({
      kind: "abstention",
      reason: "insufficient-history",
      evidenceCount: 4,
    });
  });

  it("never learns from the target event, future ground truth, another timetable, or another route", () => {
    const comparable = Array.from({ length: 5 }, (_, index) => history(index, index < 4 ? "8" : "9"));
    const excluded = [
      history(10, "99", { eventId: request().eventId }),
      history(11, "99", { finalObservedAt: "2026-08-02T08:00:00.000+02:00" }),
      history(12, "99", { serviceDate: "2025-11-01", scheduledTime: "2025-11-01T16:00:00.000+01:00" }),
      history(13, "99", { routeSignature: "route-v1-other" }),
    ];

    const result = historicalPlatformForecast(request(), [...comparable, ...excluded]);
    expect(result).toMatchObject({
      kind: "forecast",
      evidenceCount: 5,
      candidates: [
        { platform: "8", observationCount: 4 },
        { platform: "9", observationCount: 1 },
      ],
    });
    expect(result.kind === "forecast" && result.candidates.some((candidate) => candidate.platform === "99")).toBe(false);
  });

  it("uses the strict weekday/time cohort and Bayesian smoothing from the same route", () => {
    const observations = [
      history(0, "8", { scheduledTime: "2026-07-01T10:00:00.000+02:00" }),
      history(1, "9", { scheduledTime: "2026-07-02T10:00:00.000+02:00" }),
      history(2, "9", { scheduledTime: "2026-07-03T10:00:00.000+02:00" }),
      history(3, "8"),
      history(4, "8"),
      history(5, "9", { scheduledTime: "2026-07-06T10:00:00.000+02:00" }),
      history(10, "8"),
      history(11, "8"),
    ];

    const result = historicalPlatformForecast(request(), observations);
    expect(result).toMatchObject({
      kind: "forecast",
      cohort: "weekday-time-route",
      evidenceCount: 8,
      strictEvidenceCount: 4,
      candidates: [
        { platform: "8", probability: 0.866667, observationCount: 5 },
        { platform: "9", probability: 0.133333, observationCount: 3 },
      ],
      likelyPlatform: "8",
      confidence: "high",
      horizon: "6h-to-24h",
      modelVersion: "historical-bayes-v1",
    });
    if (result.kind === "forecast") {
      expect(result.candidates.reduce((sum, candidate) => sum + candidate.probability, 0)).toBeCloseTo(1, 10);
    }
  });

  it("falls back to the same service-route cohort without crossing direction or operator", () => {
    const comparable = Array.from({ length: 6 }, (_, index) => history(index, index < 4 ? "8" : "9", {
      scheduledTime: `2026-07-${String(index + 1).padStart(2, "0")}T10:00:00.000+02:00`,
    }));
    const excluded = [
      history(7, "99", { headsign: "Berlin Ostbahnhof" }),
      history(8, "99", { operatorName: "Another Railway" }),
    ];

    const result = historicalPlatformForecast(request(), [...comparable, ...excluded]);
    expect(result).toMatchObject({
      kind: "forecast",
      cohort: "service-route",
      evidenceCount: 6,
      strictEvidenceCount: 0,
      candidates: [
        { platform: "8", probability: 0.625, observationCount: 4 },
        { platform: "9", probability: 0.375, observationCount: 2 },
      ],
    });
  });
});
