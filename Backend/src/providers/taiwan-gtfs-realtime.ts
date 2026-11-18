import type { CanonicalTripReference, StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import type { BoardEntrySnapshot, BoardReference } from "../domain/discovery.js";
import { taiwanDate } from "./tdx-values.js";
import { traTripMayBeRunning, tdxTraSource } from "./tdx-live.js";

const mirrorStationPrefix = "eu:transitous:ttgtfs:TW:stop:TRA_";
const officialStationPrefix = "tw:tdx:TRA:";

/** The mirror encodes the agency, public train number and departure in its dated canonical ID. */
function mirrorTrain(reference: CanonicalTripReference, product: string): string | null {
  const match = /^ttgtfs:TW:trip:(\d{4}-\d{2}-\d{2}):TRA_(\d{1,6})(?:_[^\s:@]+)?@\d+$/u.exec(reference.nativeId);
  if (!match || reference.source !== "transitous" || reference.id !== `eu:transitous:${reference.nativeId}`
    || match[1] !== reference.serviceDate || product !== `TRA ${match[2]}`) return null;
  return match[2]!;
}

export function taiwanMirrorTraTrain(snapshot: TripSnapshot): string | null {
  if (snapshot.stops.length < 2 || !snapshot.stops.every(stop =>
    stop.countryCode === "TW" && /^eu:transitous:ttgtfs:TW:stop:TRA_\d+$/u.test(stop.stationId))) return null;
  return mirrorTrain(snapshot, snapshot.product);
}

function sameCall(mirror: StopSnapshot, official: StopSnapshot): boolean {
  if (official.countryCode !== "TW"
    || official.stationId !== officialStationPrefix + mirror.stationId.slice(mirrorStationPrefix.length)) return false;
  // The index drops the non-passenger event at each terminus. Every scheduled
  // passenger event must still agree, including both sides of a midnight dwell.
  const clocks = [
    [mirror.scheduledArrival, official.scheduledArrival], [mirror.scheduledDeparture, official.scheduledDeparture],
  ] as const;
  return clocks.some(([ours]) => ours !== null) && clocks.every(([ours, theirs]) =>
    ours === null || (theirs !== null && Date.parse(ours) === Date.parse(theirs)));
}

export function freshTdxObservation(clock: string | undefined | null, now: Date): clock is string {
  if (!clock) return false;
  const age = now.getTime() - Date.parse(clock);
  return age >= 0 && age <= 5 * 60_000;
}

function applyReportedCall(stop: StopSnapshot, report: StopSnapshot, now: Date): StopSnapshot {
  const updated = { ...stop };
  if (report.platformSource === tdxTraSource && report.expectedPlatform && freshTdxObservation(report.platformObservedAt, now)) {
    updated.expectedPlatform = report.expectedPlatform;
    updated.platformSource = report.platformSource;
    updated.platformObservedAt = report.platformObservedAt;
  }
  if (report.cancelled) {
    if (freshTdxObservation(report.cancellationObservedAt, now)) {
      updated.cancelled = true;
      updated.cancellationObservedAt = report.cancellationObservedAt;
    }
    return updated;
  }
  if (stop.scheduledArrival && report.expectedArrival && report.expectedArrivalEvidence?.source === tdxTraSource
    && freshTdxObservation(report.expectedArrivalEvidence.observedAt, now)) {
    updated.expectedArrival = report.expectedArrival;
    updated.expectedArrivalEvidence = report.expectedArrivalEvidence;
  }
  if (stop.scheduledDeparture && report.expectedDeparture && report.expectedDepartureEvidence?.source === tdxTraSource
    && freshTdxObservation(report.expectedDepartureEvidence.observedAt, now)) {
    updated.expectedDeparture = report.expectedDeparture;
    updated.expectedDepartureEvidence = report.expectedDepartureEvidence;
  }
  if (report.passed && freshTdxObservation(report.passageObservedAt, now)) {
    updated.passed = true;
    updated.passageObservedAt = report.passageObservedAt;
  }
  if (freshTdxObservation(report.arrivalObservedAt, now)) updated.arrivalObservedAt = report.arrivalObservedAt;
  return updated;
}

/** Keeps the booked GTFS identity and itinerary when applying the official dated service. */
export async function enrichTaiwanMirrorTrip(
  snapshot: TripSnapshot, fetchOfficial: (reference: CanonicalTripReference) => Promise<TripSnapshot>,
  clock?: Date,
): Promise<TripSnapshot> {
  const train = taiwanMirrorTraTrain(snapshot);
  if (!train || !traTripMayBeRunning(snapshot.stops, clock ?? new Date())) return snapshot;
  const nativeId = `TRA:${train}`;
  const reference = { source: "tdx" as const, nativeId, id: `tw:tdx:${nativeId}`, serviceDate: snapshot.serviceDate };
  let official: TripSnapshot;
  try { official = await fetchOfficial(reference); }
  catch { return snapshot; }
  if (official.source !== "tdx" || official.id !== reference.id || official.nativeId !== nativeId
    || official.serviceDate !== snapshot.serviceDate || official.stops.length !== snapshot.stops.length
    || !snapshot.stops.every((stop, index) => sameCall(stop, official.stops[index]!))) return snapshot;

  const now = clock ?? new Date();
  const result: TripSnapshot = { ...snapshot, stops: snapshot.stops.map((stop, i) => applyReportedCall(stop, official.stops[i]!, now)) };
  const delay = official.tripLevelDelay;
  if (delay?.source === tdxTraSource && delay.scope === "whole-trip" && Number.isInteger(delay.seconds)
    && delay.seconds >= 0 && delay.seconds < 86400 && freshTdxObservation(delay.feedPublishedAt, now)) result.tripLevelDelay = delay;
  return result;
}

/** Amend only the indexed station's matching passenger call, leaving its trackable reference intact. */
export async function enrichTaiwanMirrorBoard(
  entries: BoardEntrySnapshot[], reference: BoardReference, fetchOfficial: (station: BoardReference) => Promise<BoardEntrySnapshot[]>,
  clock?: Date,
): Promise<BoardEntrySnapshot[]> {
  const code = /^ttgtfs:TW:stop:TRA_(\d+)$/u.exec(reference.nativeId)?.[1];
  const at = new Date(reference.at);
  const now = clock ?? new Date();
  if (!code || reference.stationId !== `eu:transitous:${reference.nativeId}` || reference.source !== "transitous"
    || !entries.length || !Number.isFinite(at.getTime()) || taiwanDate(at) !== taiwanDate(now)
    || Math.abs(at.getTime() - now.getTime()) > 2 * 3_600_000) return entries;
  const nativeId = `TRA:${code}`;
  let board: BoardEntrySnapshot[];
  try { board = await fetchOfficial({ ...reference, source: "tdx", stationId: `tw:tdx:${nativeId}`, nativeId }); }
  catch { return entries; }
  const assessedAt = clock ?? new Date();
  return entries.map(entry => {
    const train = mirrorTrain(entry.trip, entry.product);
    if (!train || entry.stop.stationId !== reference.stationId) return entry;
    const matches = board.filter(row => row.trip.source === "tdx" && row.trip.nativeId === `TRA:${train}`
      && row.trip.id === `tw:tdx:TRA:${train}` && row.trip.serviceDate === entry.trip.serviceDate && sameCall(entry.stop, row.stop));
    return matches.length === 1 ? { ...entry, stop: applyReportedCall(entry.stop, matches[0]!.stop, assessedAt) } : entry;
  });
}
