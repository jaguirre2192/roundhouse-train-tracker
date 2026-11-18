import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";

export interface RenfeTripDescriptor {
  tripId: string;
  startDate?: string | null;
  scheduleRelationship?: string | null;
}

export interface RenfeStopEvent {
  delay?: number | string | null;
  time?: number | string | null;
}

export interface RenfeCallUpdate {
  stopId?: string | null;
  stopSequence?: number | null;
  scheduleRelationship?: string | null;
  arrival?: RenfeStopEvent | null;
  departure?: RenfeStopEvent | null;
}

export interface RenfeTimingUpdate {
  trip: RenfeTripDescriptor;
  delay?: number | string | null;
  stopTimeUpdate?: RenfeCallUpdate[] | null;
}

function isRenfe(snapshot: TripSnapshot): boolean {
  return /renfe/iu.test(`${snapshot.operatorName} ${snapshot.nativeId}`);
}

export function renfeTripID(snapshot: TripSnapshot): string {
  return snapshot.nativeId.split(/_es-(?:Cercanías-Renfe|RENFE-Larga-Distancia-y-AVE)_/u).at(-1)!;
}

export function exactRenfeTrip(trip: RenfeTripDescriptor, snapshot: TripSnapshot): boolean {
  return isRenfe(snapshot) && trip.tripId.length > 0 && renfeTripID(snapshot) === trip.tripId
    && compatibleStartDate(trip, snapshot);
}

function compatibleStartDate(trip: RenfeTripDescriptor, snapshot: TripSnapshot): boolean {
  if (trip.startDate == null) return true;
  return trip.startDate.replaceAll("-", "") === snapshot.serviceDate.replaceAll("-", "");
}

export function renfeStationMatches(stopID: string, stop: StopSnapshot): boolean {
  if (stopID.length === 0) return false;
  return stop.stationId === stopID || stop.stationId.endsWith(`_${stopID}`)
    || stop.stationId.endsWith(`-${stopID}`);
}

export function matchingRenfeStop(
  stopID: string | null | undefined, sequence: number | null | undefined, snapshot: TripSnapshot,
): StopSnapshot | undefined {
  const id = stopID?.trim();
  // An explicit unknown station must not fall through to a different call with the same sequence.
  const matches = id ? snapshot.stops.filter((stop) => renfeStationMatches(id, stop))
    : snapshot.stops.filter((stop) => sequence != null && sequence > 0 && stop.sequence === sequence);
  return matches.length === 1 ? matches[0] : undefined;
}

function finite(value: unknown): number | null {
  if (value == null || value === "") return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

/** A GTFS template suffix is not the operating date. Cross-template joins require matching
 * train AND variant plus an independently matching station and absolute scheduled event.
 * Fresh feed headers alone do not prove that every included update belongs to today's run. */
export function renfeTimingMatch(update: RenfeTimingUpdate, snapshot: TripSnapshot, observedAt: Date | null): boolean {
  if (!isRenfe(snapshot) || !compatibleStartDate(update.trip, snapshot)) return false;
  const nativeID = renfeTripID(snapshot);
  const exact = update.trip.tripId === nativeID;
  const template = /^(\d{5})(\d{1,2})\d{4}-\d{2}-\d{2}$/u;
  const left = template.exec(nativeID), right = template.exec(update.trip.tripId);
  const sameVariant = left != null && right != null && left[1] === right[1] && left[2] === right[2];
  if (!exact && !sameVariant) return false;
  let matchingEvents = 0;
  for (const call of update.stopTimeUpdate ?? []) {
    const stop = matchingRenfeStop(call.stopId, call.stopSequence, snapshot);
    if (stop == null) continue;
    for (const [event, scheduled] of [[call.arrival, stop.scheduledArrival], [call.departure, stop.scheduledDeparture]] as const) {
      const time = finite(event?.time), delay = finite(event?.delay ?? update.delay);
      if (time == null || delay == null || scheduled == null) continue;
      const planned = Date.parse(scheduled) / 1_000;
      // Feed estimates can round to a minute; a different run or timetable is not a match.
      if (!Number.isFinite(planned) || Math.abs(time - delay - planned) > 90) return false;
      matchingEvents += 1;
    }
  }
  return matchingEvents > 0 || (exact && (update.trip.startDate != null || renfeObservationOnServiceDate(snapshot, observedAt)));
}

export function renfeObservationOnServiceDate(snapshot: TripSnapshot, observedAt: Date | null): boolean {
  if (observedAt == null || !Number.isFinite(observedAt.getTime())) return false;
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Europe/Madrid", year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(observedAt);
  const value = (type: string) => parts.find((part) => part.type === type)?.value;
  return `${value("year")}-${value("month")}-${value("day")}` === snapshot.serviceDate;
}
