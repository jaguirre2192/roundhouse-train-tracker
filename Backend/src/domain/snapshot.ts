export type ProviderSource = "amtraker" | "transitous" | "srbijavoz" | "ekispert" | "tdx" | "chepe" | "db" | "sncf" | "irail" | "renfe";

export interface CanonicalTripReference {
  id: string;
  source: ProviderSource;
  nativeId: string;
  serviceDate: string;
}

export interface StopSnapshot {
  stationId: string;
  stationName: string;
  /** Local time zone published for this call, when available. */
  timeZoneIdentifier?: string;
  countryCode: string;
  latitude: number | null;
  longitude: number | null;
  sequence: number;
  scheduledArrival: string | null;
  scheduledDeparture: string | null;
  expectedArrival: string | null;
  expectedDeparture: string | null;
  /** Original publisher evidence for this component; fetching does not renew it. */
  expectedArrivalEvidence?: ExpectedTimeEvidence;
  expectedDepartureEvidence?: ExpectedTimeEvidence;
  plannedPlatform: string | null;
  expectedPlatform: string | null;
  platformSource: string | null;
  platformObservedAt: string | null;
  cancelled: boolean;
  /** Original operator clock for a cancellation reported on a live board. */
  cancellationObservedAt?: string;
  passed: boolean;
  /** Explicit operator passage/arrival reports; clock-derived flags never establish either. */
  passageObservedAt?: string;
  arrivalObservedAt?: string;
  platformForecast?: PlatformForecast;
}

export interface ExpectedTimeEvidence {
  source: string;
  observedAt: string;
}

export interface VehiclePositionSnapshot {
  latitude: number;
  longitude: number;
  heading: number | null;
  source: "real" | "inferred";
  confidence: number;
  asOf: string;
  provider: string;
  /** Explicit provenance when a provider's broken header cannot supply observation UTC. */
  timestampBasis?: "feed-publication-and-movement";
  providerReportedAt?: string;
}

export interface RouteGeometrySnapshot {
  source: string;
  segments: Array<{
    encodedPolyline: string;
    precision: number;
    pointCount: number;
  }>;
}

/// Amtrak directly (Amtraker) or an Amtrak train carried by another feed (Transitous ids
/// contain "us-Amtrak"). Amtrak stations sign tracks, so these trips never say "platform".
/// Mirrors TrainTrip.isAmtrakOperated in the app.
export function isAmtrakOperated(trip: Pick<TripSnapshot, "id" | "source" | "nativeId" | "operatorName">): boolean {
  return trip.source === "amtraker"
    || /amtrak/iu.test(trip.operatorName)
    || /us-Amtrak/iu.test(trip.id)
    || /us-Amtrak/iu.test(trip.nativeId);
}

export interface TripSnapshot extends CanonicalTripReference {
  operatorName: string;
  product: string;
  headsign: string;
  fetchedAt: string;
  stops: StopSnapshot[];
  routeGeometry?: RouteGeometrySnapshot;
  positions?: VehiclePositionSnapshot[];
  alertIds: string[];
  /** A source-published whole-trip value, never a stop forecast or watcher delay event. */
  tripLevelDelay?: { seconds: number; scope: "whole-trip"; feedPublishedAt: string; source: string };
}

export interface PushPreferences {
  delayThresholdMinutes: number;
  platformChanges: boolean;
  cancellations: boolean;
  disruptions: boolean;
}

export const defaultPushPreferences: PushPreferences = {
  delayThresholdMinutes: 5,
  platformChanges: true,
  cancellations: true,
  disruptions: true,
};

// Compares departure with departure, or arrival with arrival. Mixing an expected
// arrival with a scheduled departure would hide (or invent) the dwell time.
export function delayMinutes(stop: StopSnapshot): number | null {
  const [scheduled, expected] = stop.scheduledDeparture !== null && stop.expectedDeparture !== null
    ? [stop.scheduledDeparture, stop.expectedDeparture]
    : [stop.scheduledArrival, stop.expectedArrival];
  if (scheduled === null || expected === null) return null;
  return Math.trunc((Date.parse(expected) - Date.parse(scheduled)) / 60_000);
}
import type { PlatformForecast } from "./platform-positioning.js";
