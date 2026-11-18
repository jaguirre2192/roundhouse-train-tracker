import { coverageFeatures, type CoverageConfiguration, type TripCoverage } from "../domain/trip-coverage.js";
import type { CanonicalTripReference, TripSnapshot } from "../domain/snapshot.js";
import { tripCoveragePolicy } from "./trip-coverage-policy.js";
import { assessTraReports, isOfficialTraService, isTaiwanTimetable } from "./taiwan-trip-coverage.js";

const reviewedAt = "2026-11-13";
const detailsURL = "https://gettraintracker.com/coverage";
const emptyConfiguration: CoverageConfiguration = { enabledSources: new Set() };

function unknownCoverage(now: Date, availability: "notObserved" | "unavailable" = "notObserved"): TripCoverage {
  return {
    schemaVersion: 1, assessedAt: now.toISOString(), reviewedAt, scopeName: "Selected service",
    countryCodes: [], sourceIds: [], limitationCodes: ["coverageUnknown"], detailsURL,
    features: Object.fromEntries(coverageFeatures.map((feature) => [feature,
      { support: "unknown", availability, observedAt: null }])) as TripCoverage["features"],
  };
}

function fresh(value: string | null | undefined, now: Date): value is string {
  if (!value) return false;
  const age = now.getTime() - Date.parse(value);
  return Number.isFinite(age) && age >= -120_000 && age <= 300_000;
}

function changedForecast(scheduled: string | null, expected: string | null): boolean {
  if (scheduled === null || expected === null) return false;
  const difference = Date.parse(expected) - Date.parse(scheduled);
  return Number.isFinite(difference) && Math.abs(difference) >= 1_000 && Math.abs(difference) <= 86_400_000;
}

/** No network calls; absent observations never diagnose an outage or absent capability. */
export function assessTripCoverage(
  snapshot: TripSnapshot,
  configuration: CoverageConfiguration = emptyConfiguration,
  now: Date = new Date(),
): TripCoverage {
  const result = unknownCoverage(now);
  result.countryCodes = [...new Set(snapshot.stops.map((stop) => stop.countryCode.toUpperCase())
    .filter((code) => /^[A-Z]{2}$/u.test(code)))].sort();
  // This optional explanation must never invalidate an otherwise saveable trip.
  try {
    const policy = tripCoveragePolicy(snapshot, configuration);
    result.scopeName = policy.scopeName;
    result.sourceIds = policy.sourceIds;
    result.limitationCodes = [...policy.limitationCodes];
    for (const feature of coverageFeatures) result.features[feature].support = policy.support[feature];
  } catch {
    return result;
  }

  const observed = (feature: typeof coverageFeatures[number], observedAt: string | null) => {
    if (result.features[feature].support !== "connected" && !result.limitationCodes.includes("currentObservationOnly")) {
      result.limitationCodes.push("currentObservationOnly");
    }
    result.features[feature] = { support: "connected", availability: "observed", observedAt };
  };
  if (isTaiwanTimetable(snapshot)) {
    result.reviewedAt = "2026-11-18";
    if (result.sourceIds.includes("tdx") && isOfficialTraService(snapshot)) assessTraReports(snapshot, now, observed);
    return result;
  }
  // Components carrying explicit source provenance live by that clock, not by
  // a new fetch/reload clock. Older providers without component metadata retain
  // their existing selected-service observation boundary.
  const delayClocks = snapshot.stops.flatMap((stop) => [
    [stop.scheduledArrival, stop.expectedArrival, stop.expectedArrivalEvidence],
    [stop.scheduledDeparture, stop.expectedDeparture, stop.expectedDepartureEvidence],
  ] as const).flatMap(([scheduled, expected, evidence]): Array<string | null> => {
    if (!changedForecast(scheduled, expected)) return [];
    if (evidence !== undefined) return evidence.source.trim() && fresh(evidence.observedAt, now)
      && Date.parse(evidence.observedAt) <= now.getTime() ? [evidence.observedAt] : [];
    return fresh(snapshot.fetchedAt, now) ? [null] : [];
  });
  if (delayClocks.length > 0) observed("delays", delayClocks.filter((clock): clock is string => clock !== null)
    .sort((left, right) => Date.parse(left) - Date.parse(right)).at(-1) ?? null);
  if (fresh(snapshot.fetchedAt, now)) {
    if (snapshot.stops.some((stop) => stop.cancelled === true)) observed("cancellations", null);
    const platform = snapshot.stops.filter((stop) => stop.expectedPlatform?.trim()
      && stop.expectedPlatform !== stop.plannedPlatform
      && stop.platformSource?.trim() && stop.platformSource !== "Transitous"
      && fresh(stop.platformObservedAt, now))
      .sort((a, b) => Date.parse(b.platformObservedAt!) - Date.parse(a.platformObservedAt!))[0];
    if (platform !== undefined) observed("platforms", platform.platformObservedAt);
  }
  const point = snapshot.positions?.filter((value) => value.source === "real" && fresh(value.asOf, now)
    && Number.isFinite(value.latitude) && Math.abs(value.latitude) <= 90
    && Number.isFinite(value.longitude) && Math.abs(value.longitude) <= 180
    && (value.latitude !== 0 || value.longitude !== 0))
    .sort((a, b) => Date.parse(b.asOf) - Date.parse(a.asOf))[0];
  if (point !== undefined) observed("position", point.asOf);
  result.limitationCodes = [...new Set(result.limitationCodes)];
  return result;
}

export function failedTripCoverage(
  reference: CanonicalTripReference,
  providerUnavailable: boolean,
  now: Date = new Date(),
): TripCoverage {
  const result = unknownCoverage(now, providerUnavailable ? "unavailable" : "notObserved");
  const country = /_([a-z]{2})-[^_]+_/iu.exec(reference.nativeId)?.[1]?.toUpperCase();
  if (country !== undefined) result.countryCodes = [country];
  result.limitationCodes.push(providerUnavailable ? "providerUnavailable" : "serviceNotFound");
  return result;
}
