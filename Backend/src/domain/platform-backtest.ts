import {
  historicalPlatformForecast,
  predictionHorizon,
  type HistoricalPlatformObservation,
  type PlatformForecastAbstentionReason,
  type PlatformForecastRequest,
  type PlatformPredictionHorizon,
} from "./platform-forecast.js";
import {
  mostSpecificZoneForPlatform,
  selectPlatformForecastZone,
  type StationPlatformGeography,
} from "./platform-positioning.js";

export interface PlatformBacktestEvaluation {
  eventId: string;
  evidenceCount: number;
  likelyPlatform: string;
  actualPlatform: string;
  recommendedZoneId: string | null;
  correctZone: boolean | null;
  exactDisplayed: boolean;
  exactCorrect: boolean | null;
  harmfulDisplacement: boolean;
  topProbability: number;
}

export interface PlatformBacktestReport {
  horizon: PlatformPredictionHorizon;
  totalEvents: number;
  evaluatedForecasts: number;
  positioningForecastCount: number;
  correctZoneCount: number;
  exactDisplayedCount: number;
  exactCorrectCount: number;
  harmfulDisplacementCount: number;
  correctZoneRate: number | null;
  exactPrecision: number | null;
  harmfulDisplacementRate: number | null;
  meanAbsoluteCalibrationError: number | null;
  abstentions: Partial<Record<PlatformForecastAbstentionReason, number>>;
  evaluations: PlatformBacktestEvaluation[];
}

function rounded(value: number): number {
  return Math.round(value * 1_000_000) / 1_000_000;
}

function rate(numerator: number, denominator: number): number | null {
  return denominator === 0 ? null : rounded(numerator / denominator);
}

function requestFor(
  target: HistoricalPlatformObservation,
  leadTimeMilliseconds: number,
): PlatformForecastRequest {
  return {
    eventId: target.eventId,
    stationId: target.stationId,
    sourceName: target.sourceName,
    operatorName: target.operatorName,
    product: target.product,
    headsign: target.headsign,
    routeSignature: target.routeSignature,
    eventType: target.eventType,
    serviceDate: target.serviceDate,
    scheduledTime: target.scheduledTime,
    generatedAt: new Date(Date.parse(target.scheduledTime) - leadTimeMilliseconds).toISOString(),
    officialPlatform: null,
  };
}

export function runTemporalPlatformBacktest(
  observations: HistoricalPlatformObservation[],
  options: { geography: StationPlatformGeography; leadTimeMilliseconds: number },
): PlatformBacktestReport {
  const ordered = [...observations].sort((left, right) =>
    Date.parse(left.scheduledTime) - Date.parse(right.scheduledTime)
      || left.eventId.localeCompare(right.eventId));
  const first = ordered[0];
  const horizon = first === undefined
    ? predictionHorizon(new Date(options.leadTimeMilliseconds).toISOString(), new Date(0).toISOString())
    : predictionHorizon(first.scheduledTime, requestFor(first, options.leadTimeMilliseconds).generatedAt);
  const abstentions: Partial<Record<PlatformForecastAbstentionReason, number>> = {};
  const evaluations: PlatformBacktestEvaluation[] = [];

  for (const target of ordered) {
    const forecast = historicalPlatformForecast(requestFor(target, options.leadTimeMilliseconds), ordered);
    if (forecast.kind === "abstention") {
      abstentions[forecast.reason] = (abstentions[forecast.reason] ?? 0) + 1;
      continue;
    }
    const zone = selectPlatformForecastZone(forecast.candidates, options.geography);
    const actualZone = mostSpecificZoneForPlatform(options.geography, target.effectivePlatform);
    const correctZone = zone === null ? null : zone.platforms.includes(target.effectivePlatform);
    const exactDisplayed = forecast.candidates[0]!.probability >= 0.85;
    const exactCorrect = exactDisplayed
      ? forecast.likelyPlatform === target.effectivePlatform
      : null;
    const harmfulDisplacement = zone !== null && actualZone !== null && !correctZone
      && options.geography.harmfulZonePairs.some((pair) =>
        pair.recommendedZoneId === zone.id && pair.actualZoneId === actualZone.id);
    evaluations.push({
      eventId: target.eventId,
      evidenceCount: forecast.evidenceCount,
      likelyPlatform: forecast.likelyPlatform,
      actualPlatform: target.effectivePlatform,
      recommendedZoneId: zone?.id ?? null,
      correctZone,
      exactDisplayed,
      exactCorrect,
      harmfulDisplacement,
      topProbability: forecast.candidates[0]!.probability,
    });
  }

  const positioned = evaluations.filter((evaluation) => evaluation.correctZone !== null);
  const exact = evaluations.filter((evaluation) => evaluation.exactDisplayed);
  const correctZoneCount = positioned.filter((evaluation) => evaluation.correctZone).length;
  const exactCorrectCount = exact.filter((evaluation) => evaluation.exactCorrect).length;
  const harmfulDisplacementCount = positioned.filter((evaluation) => evaluation.harmfulDisplacement).length;
  const calibrationError = evaluations.reduce((sum, evaluation) =>
    sum + Math.abs(evaluation.topProbability - (evaluation.likelyPlatform === evaluation.actualPlatform ? 1 : 0)), 0);

  return {
    horizon,
    totalEvents: ordered.length,
    evaluatedForecasts: evaluations.length,
    positioningForecastCount: positioned.length,
    correctZoneCount,
    exactDisplayedCount: exact.length,
    exactCorrectCount,
    harmfulDisplacementCount,
    correctZoneRate: rate(correctZoneCount, positioned.length),
    exactPrecision: rate(exactCorrectCount, exact.length),
    harmfulDisplacementRate: rate(harmfulDisplacementCount, positioned.length),
    meanAbsoluteCalibrationError: evaluations.length === 0
      ? null
      : rounded(calibrationError / evaluations.length),
    abstentions,
    evaluations,
  };
}
