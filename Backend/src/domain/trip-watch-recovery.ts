import type { TripSnapshot } from "./snapshot.js";
import { hasReportedArrival } from "./stop-passage.js";
import { routePositionEvidence } from "./route-position-evidence.js";
import { latestRealPosition } from "./vehicle-position-evidence.js";

export const tripWatchRecoveryWindowMilliseconds = 2 * 60 * 60_000;
export const untimedTripWatchWindowMilliseconds = 48 * 60 * 60_000;

export function tripWatchRecoveryCutoff(snapshot: TripSnapshot, now = Date.now()): number | null {
  if (!Number.isFinite(now)) return null;
  // Matched real GPS can outlive an unchanged arrival estimate. Give the observation
  // a bounded recovery grace; fetchedAt never renews a frozen provider observation.
  // The position's live-display freshness remains separate from permission to poll.
  const terminal = snapshot.stops.at(-1);
  const terminalObservation = terminal === undefined ? Number.NaN : Math.max(...[
    terminal.arrivalObservedAt, terminal.passed ? terminal.passageObservedAt : undefined,
  ].flatMap((value) => {
    const parsed = value === undefined ? Number.NaN : Date.parse(value);
    return Number.isFinite(parsed) && parsed <= now + 120_000 ? [parsed] : [];
  }));
  const freshPosition = latestRealPosition(snapshot.positions, now);
  const observedRoute = freshPosition === null ? null : routePositionEvidence(snapshot, snapshot.stops, freshPosition);
  const contradictsArrival = freshPosition !== null && Date.parse(freshPosition.asOf) > terminalObservation
    && observedRoute?.isClearlyBeforeDestination === true;
  const arrivalConfirmed = terminal !== undefined && hasReportedArrival(terminal, new Date(now).toISOString())
    && !contradictsArrival;
  const position = arrivalConfirmed ? null : latestRealPosition(snapshot.positions, now, tripWatchRecoveryWindowMilliseconds);
  const observationCutoffs = position === null ? [] : [Date.parse(position.asOf) + tripWatchRecoveryWindowMilliseconds];
  for (const stop of snapshot.stops) {
    if (arrivalConfirmed || stop.cancelled || !hasReportedArrival(stop, new Date(now).toISOString())) continue;
    for (const value of [stop.arrivalObservedAt, stop.passed ? stop.passageObservedAt : undefined]) {
      const observed = value === undefined ? Number.NaN : Date.parse(value);
      if (Number.isFinite(observed) && observed <= now + 120_000) {
        observationCutoffs.push(observed + tripWatchRecoveryWindowMilliseconds);
      }
    }
  }
  const timetableTimes = snapshot.stops.flatMap((stop) => [
    stop.scheduledArrival,
    stop.scheduledDeparture,
    stop.expectedArrival,
    stop.expectedDeparture,
  ]).flatMap((value) => {
    if (value === null) return [];
    const parsed = Date.parse(value);
    return Number.isFinite(parsed) ? [parsed] : [];
  });
  if (timetableTimes.length > 0) {
    return Math.max(Math.max(...timetableTimes) + tripWatchRecoveryWindowMilliseconds, ...observationCutoffs);
  }

  const serviceDay = Date.parse(`${snapshot.serviceDate}T00:00:00.000Z`);
  const cutoffs = Number.isFinite(serviceDay)
    ? [serviceDay + untimedTripWatchWindowMilliseconds, ...observationCutoffs]
    : observationCutoffs;
  return cutoffs.length > 0 ? Math.max(...cutoffs) : null;
}

/// Provider passed flags can be inferred. Timetable time and actual position-observation
/// time grant bounded recovery, matching the app; an HTTP success alone grants none.
export function shouldRetireTripWatch(snapshot: TripSnapshot, now = Date.now()): boolean {
  const cutoff = tripWatchRecoveryCutoff(snapshot, now);
  return cutoff === null || !Number.isFinite(now) || now > cutoff;
}

/** An overlay timeout must not erase the bounded chance to recover on the next poll. */
export function carryForwardRecoveryPosition(
  previous: TripSnapshot | null, current: TripSnapshot, now = Date.now(),
): TripSnapshot {
  if (previous === null || previous.source !== current.source || previous.nativeId !== current.nativeId
    || previous.serviceDate !== current.serviceDate
    || latestRealPosition(current.positions, now, tripWatchRecoveryWindowMilliseconds) !== null) return current;
  const retained = latestRealPosition(previous.positions, now, tripWatchRecoveryWindowMilliseconds);
  return retained === null ? current : { ...current, positions: [...(current.positions ?? []), retained] };
}
