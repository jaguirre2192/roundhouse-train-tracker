import { hasReportedArrival, hasReportedPassage } from "./stop-passage.js";
import type { CanonicalTripReference, StopSnapshot, TripSnapshot } from "./snapshot.js";

export const afterArrival = 60 * 60_000;
export const unreportedArrivalGrace = 12 * afterArrival;

export interface ArrivalBoardRequest {
  trip: CanonicalTripReference;
  stationId: string;
  sequence: number;
  timeZone: string | null;
  note: string | null;
}

export interface ArrivalBoardRecord extends ArrivalBoardRequest {
  station: string;
  service: string;
  scheduled: string | null;
}

export interface ArrivalReport {
  observedAt: string;
  kind: "arrived" | "passed";
}

export interface ArrivalBoardView {
  station: string;
  service: string;
  timeZone: string;
  note: string | null;
  scheduled: string | null;
  time: string | null;
  basis: "arrived" | "passed" | "estimated" | "scheduled" | "cancelled" | "unavailable";
  delayMinutes: number | null;
  checkedAt: string | null;
  reportedAt: string | null;
  updatesAvailable: boolean;
  expiresAt: string;
  credit: string;
}

export function selectedCall(trip: TripSnapshot, selection: Pick<ArrivalBoardRequest, "stationId" | "sequence">): StopSnapshot | null {
  const exact = trip.stops.filter(s => s.stationId === selection.stationId && s.sequence === selection.sequence);
  return exact.length === 1 ? exact[0]! : null;
}

export function instant(value: string | null | undefined): string | null {
  if (!value || !/T.*(?:Z|[+-]\d\d:\d\d)$/iu.test(value)) return null;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? new Date(parsed).toISOString() : null;
}

export function arrivalReport(stop: StopSnapshot, now: number): ArrivalReport | null {
  const reference = new Date(now).toISOString();
  if (!hasReportedArrival(stop, reference)) return null;
  const arrival = instant(stop.arrivalObservedAt);
  if (arrival && Date.parse(arrival) <= now + 120_000) return { kind: "arrived", observedAt: arrival };
  const passage = instant(stop.passageObservedAt);
  return hasReportedPassage(stop, reference) && passage ? { kind: "passed", observedAt: passage } : null;
}

const credit: Partial<Record<CanonicalTripReference["source"], string>> = {
  amtraker: "Amtraker", transitous: "Transitous", srbijavoz: "Srbija Voz", ekispert: "Ekispert", tdx: "TDX", chepe: "Chepe",
};

function estimate(stop: StopSnapshot | null, now: number, fetchedAt: string | null): string | null {
  if (!stop) return null;
  const value = instant(stop.expectedArrival);
  if (!value) return null;
  const evidence = stop.expectedArrivalEvidence;
  if (evidence) {
    const published = instant(evidence.observedAt);
    if (!published || Date.parse(published) > now + 120_000 || now - Date.parse(published) > 30 * 60_000) return null;
  } else {
    // An undated provider forecast can be described as checked. Fetching old cached data
    // cannot make the forecast current, or turn a timetable echo into an on-time report.
    const checked = instant(fetchedAt);
    if (value === instant(stop.scheduledArrival) || !checked || Date.parse(checked) > now + 120_000
      || now - Date.parse(checked) > 30 * 60_000) return null;
  }
  return value;
}

function validatedTimeZone(identifier: string | undefined): string | null {
  if (!identifier) return null;
  try { return new Intl.DateTimeFormat("en", { timeZone: identifier }).resolvedOptions().timeZone; }
  catch { return null; }
}

export function makeBoardRecord(input: ArrivalBoardRequest, snapshot: TripSnapshot, call: StopSnapshot): ArrivalBoardRecord {
  return {
    ...input, trip: { id: snapshot.id, serviceDate: snapshot.serviceDate, source: snapshot.source, nativeId: snapshot.nativeId },
    timeZone: validatedTimeZone(call.timeZoneIdentifier) ?? input.timeZone,
    station: call.stationName, service: snapshot.product || snapshot.operatorName,
    scheduled: instant(call.scheduledArrival),
  };
}

export function fallbackExpiry(stop: StopSnapshot, now: number, fetchedAt: string): number | null {
  const arrivals = [instant(stop.scheduledArrival), estimate(stop, now, fetchedAt)].filter((v): v is string => v !== null);
  return arrivals.length ? Math.max(...arrivals.map(Date.parse)) + unreportedArrivalGrace : null;
}

export function boardView(record: ArrivalBoardRecord, stop: StopSnapshot | null, checkedAt: string | null,
  report: ArrivalReport | null, expiresAt: number, now: number): ArrivalBoardView {
  const scheduled = instant(stop?.scheduledArrival) ?? record.scheduled;
  const checked = instant(checkedAt);
  const lastCheck = checked && Date.parse(checked) <= now + 120_000 ? checked : null;
  const expected = estimate(stop, now, lastCheck);
  const evidence = stop?.expectedArrivalEvidence;
  const status = report?.kind ?? (stop?.cancelled ? "cancelled" : expected ? "estimated" : scheduled ? "scheduled" : "unavailable");
  const time = report?.observedAt ?? (status === "cancelled" ? null : expected ?? scheduled);
  const delayMinutes = (status === "estimated" || status === "arrived") && scheduled && time
    ? Math.round((Date.parse(time) - Date.parse(scheduled)) / 60_000) : null;
  return { station: record.station, service: record.service, timeZone: record.timeZone ?? "UTC",
    note: record.note, scheduled, time, basis: status, delayMinutes, checkedAt: lastCheck,
    reportedAt: report?.observedAt ?? (expected ? instant(evidence?.observedAt) : null),
    updatesAvailable: stop !== null, expiresAt: new Date(expiresAt).toISOString(), credit: credit[record.trip.source] ?? "" };
}
