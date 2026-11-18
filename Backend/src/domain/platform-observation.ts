import type { ProviderSource, StopSnapshot, TripSnapshot } from "./snapshot.js";

export type PredictionMarket = "western-europe" | "north-america";
export type ObservationTrigger = "snapshot" | "watcher";
export type PlatformObservationPolicyStatus = "enabled" | "review-required" | "prohibited";

export interface PlatformObservationPolicy {
  sourceName: string;
  status: PlatformObservationPolicyStatus;
  license: string | null;
  attribution: string | null;
  evidenceURL: string | null;
  reason: string;
}

export interface CanonicalPlatformObservationPayload {
  schemaVersion: 1;
  policyVersion: 1;
  market: PredictionMarket;
  trip: {
    id: string;
    source: ProviderSource;
    nativeId: string;
    serviceDate: string;
    operatorName: string;
    product: string;
    headsign: string;
    routeSignature: string;
  };
  stop: {
    stationId: string;
    stationName: string;
    countryCode: string;
    sequence: number;
    callType: PlatformCallType;
    scheduledArrival: string | null;
    scheduledDeparture: string | null;
    expectedArrival: string | null;
    expectedDeparture: string | null;
    plannedPlatform: string | null;
    expectedPlatform: string | null;
    effectivePlatform: string;
    passed: boolean;
    cancelled: boolean;
  };
  provenance: {
    sourceName: string;
    sourceObservedAt: string;
    snapshotFetchedAt: string;
    collectionTrigger: ObservationTrigger;
    license: string;
    attribution: string;
    evidenceURL: string;
    schedule?: {
      sourceName: string;
      license: string;
      attribution: string;
      evidenceURL: string;
    };
  };
}

export type PlatformCallType = "arrival" | "departure" | "arrival-departure" | "unknown";

export interface CanonicalPlatformObservation {
  fingerprint: string;
  market: PredictionMarket;
  countryCode: string;
  policyVersion: 1;
  sourceName: string;
  sourceLicense: string;
  sourceAttribution: string;
  sourceEvidenceURL: string;
  tripId: string;
  tripSource: ProviderSource;
  nativeTripId: string;
  serviceDate: string;
  operatorName: string;
  product: string;
  headsign: string;
  routeSignature: string;
  stationId: string;
  stationName: string;
  stopSequence: number;
  callType: PlatformCallType;
  scheduledArrival: string | null;
  scheduledDeparture: string | null;
  expectedArrival: string | null;
  expectedDeparture: string | null;
  plannedPlatform: string | null;
  expectedPlatform: string | null;
  effectivePlatform: string;
  platformObservedAt: string;
  snapshotFetchedAt: string;
  collectionTrigger: ObservationTrigger;
  firstObservedAt: string;
  lastObservedAt: string;
  sampleCount: 1;
  passed: boolean;
  cancelled: boolean;
  payload: CanonicalPlatformObservationPayload;
}

export interface SkippedPlatformObservation {
  stationId: string;
  sourceName: string;
  status: Exclude<PlatformObservationPolicyStatus, "enabled">;
  reason: string;
}

export interface PlatformObservationProjection {
  observations: CanonicalPlatformObservation[];
  skipped: SkippedPlatformObservation[];
}

const westernEuropeCountryCodes = new Set([
  "AD", "AT", "BE", "CH", "DE", "DK", "ES", "FI", "FR", "GB", "IE", "IS",
  "IT", "LI", "LU", "MC", "NL", "NO", "PT", "SE", "SM", "VA",
]);
const northAmericaCountryCodes = new Set(["CA", "MX", "US"]);

const enabledPolicies: Readonly<Record<string, PlatformObservationPolicy>> = {
  "DB Timetables": {
    sourceName: "DB Timetables",
    status: "enabled",
    license: "CC BY 4.0",
    attribution: "Deutsche Bahn AG",
    evidenceURL: "https://developers.deutschebahn.com/db-api-marketplace/apis/product/timetables",
    reason: "The feed is published for external solutions under CC BY 4.0.",
  },
  "Translink NI Opendata API": {
    sourceName: "Translink NI Opendata API",
    status: "enabled",
    license: "Translink Transport Data API Licence and User Agreement",
    attribution: "Transport Information supplied by Translink Opendata API",
    evidenceURL: "https://www.translink.co.uk/translinkpublictransportapi",
    reason: "The issued licence permits copying, publishing, distribution, transmission, adaptation, and commercial or noncommercial use with attribution.",
  },
};

export function predictionMarket(countryCode: string): PredictionMarket | null {
  const code = countryCode.trim().toUpperCase();
  if (westernEuropeCountryCodes.has(code)) return "western-europe";
  if (northAmericaCountryCodes.has(code)) return "north-america";
  return null;
}

export function platformObservationPolicy(sourceName: string): PlatformObservationPolicy {
  return enabledPolicies[sourceName] ?? {
    sourceName,
    status: "review-required",
    license: null,
    attribution: null,
    evidenceURL: null,
    reason: "No feed-specific retention basis has been recorded.",
  };
}

function fnv1a(value: string, seed: number): string {
  let hash = seed >>> 0;
  for (const character of value) {
    hash ^= character.codePointAt(0) ?? 0;
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}

function digest(value: string): string {
  return [
    fnv1a(value, 0x811c9dc5),
    fnv1a(value, 0x9e3779b9),
    fnv1a(value, 0x85ebca6b),
    fnv1a(value, 0xc2b2ae35),
  ].join("");
}

export function routeSignature(snapshot: TripSnapshot): string {
  const route = snapshot.stops.map((stop) => `${stop.sequence}:${stop.stationId}`).join("|");
  return `route-v1-${digest(route)}`;
}

function normalizedPlatform(value: string | null): string | null {
  const normalized = value?.trim();
  return normalized === undefined || normalized.length === 0 ? null : normalized;
}

function callType(stop: StopSnapshot): PlatformCallType {
  if (stop.scheduledArrival !== null && stop.scheduledDeparture !== null) return "arrival-departure";
  if (stop.scheduledArrival !== null) return "arrival";
  if (stop.scheduledDeparture !== null) return "departure";
  return "unknown";
}

function scheduleProvenance(snapshot: TripSnapshot): CanonicalPlatformObservationPayload["provenance"]["schedule"] {
  if (snapshot.source !== "transitous" || !/_de-DELFI_/u.test(snapshot.nativeId)) return undefined;
  return {
    sourceName: "DELFI",
    license: "CC BY 4.0",
    attribution: "DELFI e.V.",
    evidenceURL: "https://transitous.org/sources/",
  };
}

function stateFingerprint(
  snapshot: TripSnapshot,
  stop: StopSnapshot,
  sourceName: string,
  plannedPlatform: string | null,
  expectedPlatform: string | null,
  effectivePlatform: string,
  expectedArrival: string | null,
  expectedDeparture: string | null,
): string {
  return `platform-v1-${digest(JSON.stringify({
    policyVersion: 1,
    sourceName,
    tripSource: snapshot.source,
    nativeTripId: snapshot.nativeId,
    serviceDate: snapshot.serviceDate,
    stationId: stop.stationId,
    stopSequence: stop.sequence,
    scheduledArrival: stop.scheduledArrival,
    scheduledDeparture: stop.scheduledDeparture,
    expectedArrival,
    expectedDeparture,
    plannedPlatform,
    expectedPlatform,
    effectivePlatform,
    cancelled: stop.cancelled,
  }))}`;
}

export function projectPlatformObservations(
  snapshot: TripSnapshot,
  trigger: ObservationTrigger,
): PlatformObservationProjection {
  const observations: CanonicalPlatformObservation[] = [];
  const skipped: SkippedPlatformObservation[] = [];
  const signature = routeSignature(snapshot);

  for (const stop of snapshot.stops) {
    const market = predictionMarket(stop.countryCode);
    const plannedPlatform = normalizedPlatform(stop.plannedPlatform);
    const expectedPlatform = normalizedPlatform(stop.expectedPlatform);
    const effectivePlatform = expectedPlatform ?? plannedPlatform;
    const sourceName = stop.platformSource?.trim() ?? "";
    if (market === null || effectivePlatform === null || sourceName.length === 0) continue;

    const policy = platformObservationPolicy(sourceName);
    if (policy.status !== "enabled") {
      skipped.push({
        stationId: stop.stationId,
        sourceName,
        status: policy.status,
        reason: policy.reason,
      });
      continue;
    }

    if (policy.license === null || policy.attribution === null || policy.evidenceURL === null) {
      throw new Error(`Enabled platform observation policy lacks provenance: ${sourceName}`);
    }

    const countryCode = stop.countryCode.toUpperCase();
    const sourceObservedAt = stop.platformObservedAt ?? snapshot.fetchedAt;
    const stopCallType = callType(stop);
    // DB Timetables is the approved source for the retained platform state, but a
    // normalized stop can otherwise contain expected-time values from a different
    // overlay. Prediction uses scheduled time, so omit those mixed-source fields.
    const expectedArrival = sourceName === "DB Timetables" ? null : stop.expectedArrival;
    const expectedDeparture = sourceName === "DB Timetables" ? null : stop.expectedDeparture;
    const schedule = scheduleProvenance(snapshot);
    const payload: CanonicalPlatformObservationPayload = {
      schemaVersion: 1,
      policyVersion: 1,
      market,
      trip: {
        id: snapshot.id,
        source: snapshot.source,
        nativeId: snapshot.nativeId,
        serviceDate: snapshot.serviceDate,
        operatorName: snapshot.operatorName,
        product: snapshot.product,
        headsign: snapshot.headsign,
        routeSignature: signature,
      },
      stop: {
        stationId: stop.stationId,
        stationName: stop.stationName,
        countryCode,
        sequence: stop.sequence,
        callType: stopCallType,
        scheduledArrival: stop.scheduledArrival,
        scheduledDeparture: stop.scheduledDeparture,
        expectedArrival,
        expectedDeparture,
        plannedPlatform,
        expectedPlatform,
        effectivePlatform,
        passed: stop.passed,
        cancelled: stop.cancelled,
      },
      provenance: {
        sourceName,
        sourceObservedAt,
        snapshotFetchedAt: snapshot.fetchedAt,
        collectionTrigger: trigger,
        license: policy.license,
        attribution: policy.attribution,
        evidenceURL: policy.evidenceURL,
        ...(schedule === undefined ? {} : { schedule }),
      },
    };

    observations.push({
      fingerprint: stateFingerprint(
        snapshot,
        stop,
        sourceName,
        plannedPlatform,
        expectedPlatform,
        effectivePlatform,
        expectedArrival,
        expectedDeparture,
      ),
      market,
      countryCode,
      policyVersion: 1,
      sourceName,
      sourceLicense: policy.license,
      sourceAttribution: policy.attribution,
      sourceEvidenceURL: policy.evidenceURL,
      tripId: snapshot.id,
      tripSource: snapshot.source,
      nativeTripId: snapshot.nativeId,
      serviceDate: snapshot.serviceDate,
      operatorName: snapshot.operatorName,
      product: snapshot.product,
      headsign: snapshot.headsign,
      routeSignature: signature,
      stationId: stop.stationId,
      stationName: stop.stationName,
      stopSequence: stop.sequence,
      callType: stopCallType,
      scheduledArrival: stop.scheduledArrival,
      scheduledDeparture: stop.scheduledDeparture,
      expectedArrival,
      expectedDeparture,
      plannedPlatform,
      expectedPlatform,
      effectivePlatform,
      platformObservedAt: sourceObservedAt,
      snapshotFetchedAt: snapshot.fetchedAt,
      collectionTrigger: trigger,
      firstObservedAt: snapshot.fetchedAt,
      lastObservedAt: snapshot.fetchedAt,
      sampleCount: 1,
      passed: stop.passed,
      cancelled: stop.cancelled,
      payload,
    });
  }

  return { observations, skipped };
}
