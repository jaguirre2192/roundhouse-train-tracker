import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import { tripWatchRecoveryWindowMilliseconds } from "../domain/trip-watch-recovery.js";
import { hasReportedPassage } from "../domain/stop-passage.js";

function latestTime(stop: StopSnapshot): number | null {
  const times = [stop.expectedDeparture, stop.expectedArrival, stop.scheduledDeparture, stop.scheduledArrival]
    .flatMap((value) => value === null || !Number.isFinite(Date.parse(value)) ? [] : [Date.parse(value)]);
  return times.length > 0 ? Math.max(...times) : null;
}

/** Timetable passage is not evidence that a delayed train has left. */
export function needsRealtimeUpdate(stop: StopSnapshot, snapshot: TripSnapshot): boolean {
  const now = Date.parse(snapshot.fetchedAt);
  const time = latestTime(stop);
  // With no time boundary, an old passed flag cannot justify an unbounded recovery poll.
  if (time === null) return !stop.passed;
  return Number.isFinite(now) && time >= now - tripWatchRecoveryWindowMilliseconds;
}

/** Keep bounded recovery requests separate so they cannot displace upcoming stops. */
export function realtimeCandidateStops(
  snapshot: TripSnapshot,
  matches: (stop: StopSnapshot) => boolean = () => true,
  limitPerGroup = Infinity,
): StopSnapshot[] {
  const candidates = snapshot.stops.filter(matches);
  const now = Date.parse(snapshot.fetchedAt);
  // Recency selects requests; it is not a claim that the train reached a station.
  const recovering = candidates.filter((stop) => (latestTime(stop) ?? Infinity) < now
    && needsRealtimeUpdate(stop, snapshot));
  const upcoming = candidates.filter((stop) => (latestTime(stop) ?? Infinity) >= now
    && !hasReportedPassage(stop, snapshot.fetchedAt) && needsRealtimeUpdate(stop, snapshot));
  return [...recovering.slice(-limitPerGroup), ...upcoming.slice(0, limitPerGroup)];
}
