import {
  serviceFamily,
  type HistoricalPlatformForecast,
  type PlatformEventType,
  type PlatformForecastConfidence,
  type PlatformForecastRequest,
  type PlatformPredictionHorizon,
  type PlatformProbabilityCandidate,
} from "./platform-forecast.js";

export interface StationPlatformZone {
  id: string;
  label: string;
  platforms: string[];
}

export interface StationPlatformGeography {
  stationId: string;
  version: string;
  verifiedAt: string;
  validUntil: string;
  neutralZoneId: string;
  zones: StationPlatformZone[];
  harmfulZonePairs: Array<{ recommendedZoneId: string; actualZoneId: string }>;
}

export interface QualifiedPlatformForecastCohort {
  stationId: string;
  sourceName: string;
  serviceFamily: string;
  eventType: PlatformEventType;
  horizon: PlatformPredictionHorizon;
  correctZoneRate: number;
  exactPrecision: number;
  harmfulDisplacementRate: number;
  exactDisplayEnabled: boolean;
}

export interface PlatformForecastReleasePolicy {
  globalDisplayEnabled: boolean;
  disabledSources: string[];
  disabledStations: string[];
  qualifiedCohorts: QualifiedPlatformForecastCohort[];
}

export interface PlatformForecastZone {
  id: string;
  label: string;
  platforms: string[];
  probability: number;
}

export interface PlatformForecast {
  kind: "forecast";
  state: "positioning" | "likely-platform";
  zone: PlatformForecastZone;
  candidates: PlatformProbabilityCandidate[];
  likelyPlatform: string | null;
  confidence: PlatformForecastConfidence;
  evidenceCount: number;
  explanation: string;
  horizon: PlatformPredictionHorizon;
  modelVersion: string;
  timetablePeriod: string;
  stationMapVersion: string;
  generatedAt: string;
  expiresAt: string;
}

export type PlatformPositioningAbstentionReason =
  | "release-disabled"
  | "no-station-geography"
  | "station-map-expired"
  | "forecast-expired"
  | "insufficient-customer-history"
  | "cohort-unqualified"
  | "platform-not-mapped"
  | "zone-confidence-low";

export interface PlatformPositioningAbstention {
  kind: "abstention";
  reason: PlatformPositioningAbstentionReason;
}

export const productionStationPlatformGeographies: StationPlatformGeography[] = [];

export const productionPlatformForecastReleasePolicy: PlatformForecastReleasePolicy = {
  globalDisplayEnabled: false,
  disabledSources: [],
  disabledStations: [],
  qualifiedCohorts: [],
};

function normalized(value: string): string {
  return value.trim().toLocaleUpperCase("en-US");
}

function rounded(value: number): number {
  return Math.round(value * 1_000_000) / 1_000_000;
}

export function mostSpecificZoneForPlatform(
  geography: StationPlatformGeography,
  platform: string,
): StationPlatformZone | null {
  return geography.zones
    .filter((zone) => zone.platforms.includes(platform))
    .sort((left, right) => left.platforms.length - right.platforms.length
      || left.id.localeCompare(right.id))[0] ?? null;
}

export function selectPlatformForecastZone(
  candidates: PlatformProbabilityCandidate[],
  geography: StationPlatformGeography,
): PlatformForecastZone | null {
  const eligible = geography.zones.map((zone) => ({
    ...zone,
    probability: candidates.reduce(
      (sum, candidate) => sum + (zone.platforms.includes(candidate.platform) ? candidate.probability : 0),
      0,
    ),
  })).filter((zone) => zone.probability + 1e-9 >= 0.9)
    .sort((left, right) => left.platforms.length - right.platforms.length
      || right.probability - left.probability
      || left.id.localeCompare(right.id));
  const selected = eligible[0];
  return selected === undefined ? null : {
    id: selected.id,
    label: selected.label,
    platforms: selected.platforms,
    probability: rounded(selected.probability),
  };
}

function qualifiedCohort(
  request: PlatformForecastRequest,
  forecast: HistoricalPlatformForecast,
  policy: PlatformForecastReleasePolicy,
): QualifiedPlatformForecastCohort | null {
  return policy.qualifiedCohorts.find((cohort) =>
    cohort.stationId === request.stationId
      && normalized(cohort.sourceName) === normalized(request.sourceName)
      && normalized(cohort.serviceFamily) === normalized(serviceFamily(request.product))
      && cohort.eventType === request.eventType
      && cohort.horizon === forecast.horizon) ?? null;
}

export function positionPlatformForecast(input: {
  request: PlatformForecastRequest;
  historical: HistoricalPlatformForecast;
  geography: StationPlatformGeography | null;
  policy: PlatformForecastReleasePolicy;
  now: string;
}): PlatformForecast | PlatformPositioningAbstention {
  const { request, historical, geography, policy } = input;
  if (!policy.globalDisplayEnabled
    || policy.disabledSources.some((source) => normalized(source) === normalized(request.sourceName))
    || policy.disabledStations.includes(request.stationId)) {
    return { kind: "abstention", reason: "release-disabled" };
  }
  if (geography === null || geography.stationId !== request.stationId) {
    return { kind: "abstention", reason: "no-station-geography" };
  }
  const now = Date.parse(input.now);
  if (now > Date.parse(geography.validUntil)) {
    return { kind: "abstention", reason: "station-map-expired" };
  }
  if (now >= Date.parse(historical.expiresAt)) {
    return { kind: "abstention", reason: "forecast-expired" };
  }
  if (historical.evidenceCount < 30) {
    return { kind: "abstention", reason: "insufficient-customer-history" };
  }
  const cohort = qualifiedCohort(request, historical, policy);
  if (cohort === null
    || cohort.correctZoneRate < 0.9
    || cohort.harmfulDisplacementRate >= 0.02) {
    return { kind: "abstention", reason: "cohort-unqualified" };
  }
  if (historical.candidates.some((candidate) =>
    mostSpecificZoneForPlatform(geography, candidate.platform) === null)) {
    return { kind: "abstention", reason: "platform-not-mapped" };
  }
  const zone = selectPlatformForecastZone(historical.candidates, geography);
  if (zone === null) return { kind: "abstention", reason: "zone-confidence-low" };

  const mostLikely = historical.candidates[0]!;
  const canShowExact = cohort.exactDisplayEnabled
    && cohort.exactPrecision >= 0.85
    && mostLikely.probability >= 0.85;
  return {
    kind: "forecast",
    state: canShowExact ? "likely-platform" : "positioning",
    zone,
    candidates: historical.candidates,
    likelyPlatform: canShowExact ? mostLikely.platform : null,
    confidence: historical.confidence,
    evidenceCount: historical.evidenceCount,
    explanation: historical.explanation,
    horizon: historical.horizon,
    modelVersion: historical.modelVersion,
    timetablePeriod: historical.timetablePeriod,
    stationMapVersion: geography.version,
    generatedAt: historical.generatedAt,
    expiresAt: historical.expiresAt,
  };
}
