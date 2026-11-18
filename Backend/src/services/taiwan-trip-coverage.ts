import type { TripSnapshot } from "../domain/snapshot.js";
import type { CoverageFeature } from "../domain/trip-coverage.js";
import { gtfsCountryForNativeID } from "../providers/mainline-gtfs-provider.js";
import { validGTFSDate } from "../providers/mainline-gtfs-index.js";
import { freshTdxObservation, taiwanMirrorTraTrain } from "../providers/taiwan-gtfs-realtime.js";
import { tdxTraSource } from "../providers/tdx-live.js";

export function isTaiwanTimetable(snapshot: TripSnapshot): boolean {
  return snapshot.source === "tdx"
    || (snapshot.source === "transitous" && gtfsCountryForNativeID(snapshot.nativeId) === "TW");
}

export function isOfficialTraService(snapshot: TripSnapshot): boolean {
  if (!validGTFSDate(snapshot.serviceDate)) return false;
  if (snapshot.source !== "tdx") return taiwanMirrorTraTrain(snapshot) !== null;
  return /^TRA:\d{1,6}$/u.test(snapshot.nativeId) && snapshot.id === `tw:tdx:${snapshot.nativeId}`
    && snapshot.stops.length >= 2 && snapshot.stops.every(stop =>
      stop.countryCode === "TW" && /^tw:tdx:TRA:\d+$/u.test(stop.stationId));
}

/** The TRA board can explicitly report zero delay or confirm a planned platform. */
export function assessTraReports(
  trip: TripSnapshot, now: Date, observe: (feature: CoverageFeature, observedAt: string) => void,
): void {
  const clocks = new Map<CoverageFeature, string>();
  const add = (feature: CoverageFeature, clock: string | null | undefined) => {
    if (!freshTdxObservation(clock, now)) return;
    const previous = clocks.get(feature);
    if (!previous || Date.parse(clock) > Date.parse(previous)) clocks.set(feature, clock);
  };
  for (const stop of trip.stops) {
    for (const [scheduled, expected, evidence] of [
      [stop.scheduledArrival, stop.expectedArrival, stop.expectedArrivalEvidence],
      [stop.scheduledDeparture, stop.expectedDeparture, stop.expectedDepartureEvidence],
    ] as const) {
      if (scheduled && expected && evidence?.source === tdxTraSource) {
        const delay = Date.parse(expected) - Date.parse(scheduled);
        if (delay >= 0 && delay < 86_400_000) add("delays", evidence.observedAt);
      }
    }
    if (stop.expectedPlatform?.trim() && stop.platformSource === tdxTraSource) add("platforms", stop.platformObservedAt);
    if (stop.cancelled) add("cancellations", stop.cancellationObservedAt);
  }
  const whole = trip.tripLevelDelay;
  if (whole?.source === tdxTraSource && whole.scope === "whole-trip" && Number.isInteger(whole.seconds)
    && whole.seconds >= 0 && whole.seconds < 86400) add("delays", whole.feedPublishedAt);
  for (const [feature, clock] of clocks) observe(feature, clock);
}
