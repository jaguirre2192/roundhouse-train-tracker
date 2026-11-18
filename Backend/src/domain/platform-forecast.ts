export type PlatformEventType = "arrival" | "departure";
export type PlatformPredictionHorizon =
  | "24h-plus"
  | "6h-to-24h"
  | "1h-to-6h"
  | "15m-to-1h"
  | "under-15m";
export type PlatformForecastCohort = "weekday-time-route" | "service-route";
export type PlatformForecastConfidence = "low" | "medium" | "high";
export type PlatformForecastAbstentionReason =
  | "official-platform-available"
  | "event-passed"
  | "invalid-time"
  | "insufficient-history";

export interface PlatformForecastRequest {
  eventId: string;
  stationId: string;
  sourceName: string;
  operatorName: string;
  product: string;
  headsign: string;
  routeSignature: string;
  eventType: PlatformEventType;
  serviceDate: string;
  scheduledTime: string;
  generatedAt: string;
  officialPlatform: string | null;
}

export interface HistoricalPlatformObservation {
  eventId: string;
  stationId: string;
  sourceName: string;
  operatorName: string;
  product: string;
  headsign: string;
  routeSignature: string;
  eventType: PlatformEventType;
  serviceDate: string;
  scheduledTime: string;
  effectivePlatform: string;
  finalObservedAt: string;
}

export interface PlatformProbabilityCandidate {
  platform: string;
  probability: number;
  observationCount: number;
}

export interface HistoricalPlatformForecast {
  kind: "forecast";
  cohort: PlatformForecastCohort;
  evidenceCount: number;
  strictEvidenceCount: number;
  candidates: PlatformProbabilityCandidate[];
  likelyPlatform: string;
  confidence: PlatformForecastConfidence;
  horizon: PlatformPredictionHorizon;
  timetablePeriod: string;
  modelVersion: "historical-bayes-v1";
  generatedAt: string;
  expiresAt: string;
  explanation: string;
}

export interface PlatformForecastAbstention {
  kind: "abstention";
  reason: PlatformForecastAbstentionReason;
  evidenceCount?: number;
}

const minimumShadowEvidence = 5;
const minimumStrictEvidence = 3;
const hierarchicalPriorStrength = 2;

function normalizedWords(value: string): string {
  return value
    .trim()
    .toLocaleUpperCase("en-US")
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

export function serviceFamily(product: string): string {
  return normalizedWords(product)
    .split(" ")
    .filter((part) => !/^\d+$/.test(part))
    .join(" ");
}

function secondSundayOfDecember(year: number): number {
  const first = new Date(Date.UTC(year, 11, 1));
  const firstSunday = 1 + ((7 - first.getUTCDay()) % 7);
  return firstSunday + 7;
}

export function railwayTimetablePeriod(serviceDate: string): string {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(serviceDate);
  if (match === null) return "invalid";
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const startsCurrentYear = month === 12 && day >= secondSundayOfDecember(year);
  const startYear = startsCurrentYear ? year : year - 1;
  return `${startYear}-${startYear + 1}`;
}

export function predictionHorizon(
  scheduledTime: string,
  generatedAt: string,
): PlatformPredictionHorizon {
  const difference = Date.parse(scheduledTime) - Date.parse(generatedAt);
  if (difference >= 24 * 60 * 60_000) return "24h-plus";
  if (difference >= 6 * 60 * 60_000) return "6h-to-24h";
  if (difference >= 60 * 60_000) return "1h-to-6h";
  if (difference >= 15 * 60_000) return "15m-to-1h";
  return "under-15m";
}

function eventTimeBucket(value: string): number {
  const match = /^\d{4}-\d{2}-\d{2}T(\d{2}):/.exec(value);
  return match === null ? -1 : Math.floor(Number(match[1]) / 2);
}

function weekdayClass(serviceDate: string): "weekday" | "weekend" | "invalid" {
  const time = Date.parse(`${serviceDate}T00:00:00.000Z`);
  if (!Number.isFinite(time)) return "invalid";
  const day = new Date(time).getUTCDay();
  return day === 0 || day === 6 ? "weekend" : "weekday";
}

function sameBaseCohort(
  request: PlatformForecastRequest,
  observation: HistoricalPlatformObservation,
): boolean {
  return observation.eventId !== request.eventId
    && observation.stationId === request.stationId
    && normalizedWords(observation.sourceName) === normalizedWords(request.sourceName)
    && normalizedWords(observation.operatorName) === normalizedWords(request.operatorName)
    && serviceFamily(observation.product) === serviceFamily(request.product)
    && normalizedWords(observation.headsign) === normalizedWords(request.headsign)
    && observation.routeSignature === request.routeSignature
    && observation.eventType === request.eventType
    && railwayTimetablePeriod(observation.serviceDate) === railwayTimetablePeriod(request.serviceDate)
    && Date.parse(observation.finalObservedAt) < Date.parse(request.generatedAt)
    && Date.parse(observation.scheduledTime) < Date.parse(request.scheduledTime)
    && observation.effectivePlatform.trim().length > 0;
}

function countPlatforms(observations: HistoricalPlatformObservation[]): Map<string, number> {
  const counts = new Map<string, number>();
  for (const observation of observations) {
    const platform = observation.effectivePlatform.trim();
    counts.set(platform, (counts.get(platform) ?? 0) + 1);
  }
  return counts;
}

function roundedProbability(value: number): number {
  return Math.round(value * 1_000_000) / 1_000_000;
}

function expiry(generatedAt: string, horizon: PlatformPredictionHorizon): string {
  const durations: Record<PlatformPredictionHorizon, number> = {
    "24h-plus": 6 * 60 * 60_000,
    "6h-to-24h": 2 * 60 * 60_000,
    "1h-to-6h": 30 * 60_000,
    "15m-to-1h": 10 * 60_000,
    "under-15m": 2 * 60_000,
  };
  return new Date(Date.parse(generatedAt) + durations[horizon]).toISOString();
}

function confidence(probability: number): PlatformForecastConfidence {
  if (probability >= 0.85) return "high";
  if (probability >= 0.65) return "medium";
  return "low";
}

export function historicalPlatformForecast(
  request: PlatformForecastRequest,
  history: HistoricalPlatformObservation[],
): HistoricalPlatformForecast | PlatformForecastAbstention {
  if (request.officialPlatform?.trim()) {
    return { kind: "abstention", reason: "official-platform-available" };
  }
  const generatedTime = Date.parse(request.generatedAt);
  const scheduledTime = Date.parse(request.scheduledTime);
  if (!Number.isFinite(generatedTime) || !Number.isFinite(scheduledTime)) {
    return { kind: "abstention", reason: "invalid-time" };
  }
  if (scheduledTime <= generatedTime) return { kind: "abstention", reason: "event-passed" };

  const base = history.filter((observation) => sameBaseCohort(request, observation));
  if (base.length < minimumShadowEvidence) {
    return { kind: "abstention", reason: "insufficient-history", evidenceCount: base.length };
  }

  const requestWeekdayClass = weekdayClass(request.serviceDate);
  const requestTimeBucket = eventTimeBucket(request.scheduledTime);
  const strict = base.filter((observation) =>
    weekdayClass(observation.serviceDate) === requestWeekdayClass
      && eventTimeBucket(observation.scheduledTime) === requestTimeBucket);
  const useStrict = strict.length >= minimumStrictEvidence;
  const baseCounts = countPlatforms(base);
  const selectedCounts = countPlatforms(useStrict ? strict : base);
  const platforms = [...baseCounts.keys()].sort((left, right) => {
    const difference = (baseCounts.get(right) ?? 0) - (baseCounts.get(left) ?? 0);
    return difference === 0 ? left.localeCompare(right, "en", { numeric: true }) : difference;
  });
  const priorDenominator = base.length + platforms.length;
  const selectedDenominator = useStrict
    ? strict.length + hierarchicalPriorStrength
    : priorDenominator;
  const rawProbabilities = platforms.map((platform) => {
    const baseCount = baseCounts.get(platform) ?? 0;
    const prior = (baseCount + 1) / priorDenominator;
    const probability = useStrict
      ? ((selectedCounts.get(platform) ?? 0) + hierarchicalPriorStrength * prior) / selectedDenominator
      : prior;
    return probability;
  });
  const rounded = rawProbabilities.map(roundedProbability);
  if (rounded.length > 0) {
    const preceding = rounded.slice(0, -1).reduce((sum, value) => sum + value, 0);
    rounded[rounded.length - 1] = roundedProbability(1 - preceding);
  }
  const candidates = platforms.map((platform, index) => ({
    platform,
    probability: rounded[index] ?? 0,
    observationCount: baseCounts.get(platform) ?? 0,
  })).sort((left, right) => right.probability - left.probability
    || left.platform.localeCompare(right.platform, "en", { numeric: true }));
  const likely = candidates[0]!;
  const horizon = predictionHorizon(request.scheduledTime, request.generatedAt);

  return {
    kind: "forecast",
    cohort: useStrict ? "weekday-time-route" : "service-route",
    evidenceCount: base.length,
    strictEvidenceCount: useStrict ? strict.length : 0,
    candidates,
    likelyPlatform: likely.platform,
    confidence: confidence(likely.probability),
    horizon,
    timetablePeriod: railwayTimetablePeriod(request.serviceDate),
    modelVersion: "historical-bayes-v1",
    generatedAt: new Date(generatedTime).toISOString(),
    expiresAt: expiry(request.generatedAt, horizon),
    explanation: `${base.length} completed comparable services in ${railwayTimetablePeriod(request.serviceDate)}.`,
  };
}
