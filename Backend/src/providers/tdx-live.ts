import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import type { TdxStopTime, TraStationReport, TraTrainReport } from "./tdx-types.js";
import { taiwanDate, tdxTimestamp } from "./tdx-values.js";

export const tdxTraSource = "TDX Taiwan Railway";
const minute = 60_000;

// Only the individual observation records a train's status. The wrapper's
// publication time may advance while repeating an old/undated observation.
function observationTime(value: string | null | undefined, now: Date): string | null {
  if (!value || !/(?:Z|[+-]\d{2}:\d{2})$/iu.test(value)) return null;
  const time = Date.parse(value), age = now.getTime() - time;
  return age >= -2 * minute && age <= 5 * minute ? new Date(time).toISOString() : null;
}

function delayMinutes(value: number | null | undefined): number | null {
  return typeof value === "number" && Number.isInteger(value) && value >= 0 && value < 1440 ? value : null;
}

type TimetableClocks = Pick<TdxStopTime, "ArrivalTime" | "DepartureTime">;

// Daily timetables can publish HH:mm while the station board supplies HH:mm:ss.
// Match at their shared precision, then retain the more precise clock on the dated call.
function reconciledClock(scheduled: string | null, original: string | null | undefined,
  reported: string | null | undefined): number | null {
  if (!scheduled || !original || !reported) return null;
  const planned = Date.parse(scheduled);
  const published = tdxTimestamp(taiwanDate(new Date(planned)), reported);
  if (!published) return null;
  const reportTime = Date.parse(published);
  if ((Math.floor(reportTime / minute) - Math.floor(planned / minute)) % (24 * 60) !== 0) return null;
  if (original.length > 5 && reported.length > 5 && reportTime % minute !== planned % minute) return null;
  return original.length > 5 ? planned : Math.floor(planned / minute) * minute + reportTime % minute;
}

export function applyTraStationReports(
  stop: StopSnapshot, clocks: TimetableClocks, train: string, reports: readonly TraStationReport[], now: Date,
): StopSnapshot {
  const matches = reports.flatMap(row => {
    if (row.TrainNo !== train || stop.stationId !== `tw:tdx:TRA:${row.StationID}`) return [];
    const observedAt = observationTime(row.UpdateTime, now);
    if (!observedAt) return [];
    const arrival = reconciledClock(stop.scheduledArrival, clocks.ArrivalTime, row.ScheduleArrivalTime);
    const departure = reconciledClock(stop.scheduledDeparture, clocks.DepartureTime, row.ScheduleDepartureTime);
    if (arrival === null && departure === null) return [];
    if ((stop.scheduledArrival && row.ScheduleArrivalTime && arrival === null)
      || (stop.scheduledDeparture && row.ScheduleDepartureTime && departure === null)) return [];
    return [{ report: row, observedAt, arrival, departure }];
  });
  if (matches.length !== 1) return stop;
  const { report, observedAt, arrival, departure } = matches[0]!;
  const delay = delayMinutes(report.DelayTime);
  // Time-of-day board entries have no service date. Tie them to a dated call
  // near the observation so tomorrow's copy of this train cannot borrow it.
  const hoursFromReport = ((departure ?? arrival!) + (delay ?? 0) * minute - Date.parse(observedAt)) / 3_600_000;
  if (hoursFromReport < -2 || hoursFromReport > 12) return stop;
  const updated = { ...stop };
  const platform = report.Platform?.trim();
  if (platform && !/^0+$/u.test(platform)) {
    updated.expectedPlatform = platform;
    updated.platformSource = tdxTraSource;
    updated.platformObservedAt = observedAt;
  }
  if (report.RunningStatus === 2) {
    updated.cancelled = true;
    updated.cancellationObservedAt = observedAt;
  }
  if (updated.cancelled || delay === null || (report.RunningStatus === 1 && delay === 0)
    || (report.RunningStatus === 0 && delay > 0)) return updated;
  const evidence = { source: tdxTraSource, observedAt };
  if (arrival !== null) {
    updated.expectedArrival = new Date(arrival + delay * minute).toISOString();
    updated.expectedArrivalEvidence = evidence;
  }
  if (departure !== null) {
    updated.expectedDeparture = new Date(departure + delay * minute).toISOString();
    updated.expectedDepartureEvidence = evidence;
  }
  return updated;
}

function serviceWindow(stops: readonly StopSnapshot[]): [number, number] | undefined {
  const times = stops.flatMap(stop => [stop.scheduledArrival, stop.scheduledDeparture])
    .filter((value): value is string => value !== null).map(value => Date.parse(value));
  return times.length ? [Math.min(...times), Math.max(...times)] : undefined;
}

export function traTripMayBeRunning(stops: readonly StopSnapshot[], now: Date): boolean {
  const window = serviceWindow(stops);
  return !!window && now.getTime() >= window[0] - 15 * minute && now.getTime() <= window[1] + 6 * 60 * minute;
}

export function applyTraTrainReports(
  trip: TripSnapshot, train: string, reports: readonly TraTrainReport[], now: Date,
): TripSnapshot {
  const matches = reports.filter(row => row.TrainNo === train && row.StationID && observationTime(row.UpdateTime, now));
  if (matches.length !== 1) return trip;
  const report = matches[0]!, observedAt = observationTime(report.UpdateTime, now)!;
  const delay = delayMinutes(report.DelayTime);
  const stops = trip.stops.filter(stop => stop.stationId === `tw:tdx:TRA:${report.StationID}`);
  if (stops.length > 1 || stops[0]?.cancelled) return trip;
  // The operator includes passing stations. An unmatched station can carry a
  // train-wide delay but can never mark any booked stop reached or supply GPS.
  const window = serviceWindow(stops.length ? stops : trip.stops);
  const serviceTime = Date.parse(observedAt) - (delay ?? 0) * minute;
  if (!window || serviceTime < window[0] - 15 * minute || serviceTime > window[1] + 30 * minute) return trip;
  const updated = { ...trip };
  if (delay !== null) updated.tripLevelDelay = { seconds: delay * 60, scope: "whole-trip", feedPublishedAt: observedAt, source: tdxTraSource };
  if (stops.length && (report.TrainStationStatus === 1 || report.TrainStationStatus === 2)) {
    updated.stops = trip.stops.map(stop => {
      if (stop !== stops[0]) return stop;
      return report.TrainStationStatus === 2 ? { ...stop, passed: true, passageObservedAt: observedAt }
        : { ...stop, arrivalObservedAt: observedAt };
    });
  }
  return updated;
}
