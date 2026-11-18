import { createHash } from "node:crypto";
import { delayMinutes, isAmtrakOperated, type PushPreferences, type StopSnapshot, type TripSnapshot } from "./snapshot.js";

export type MaterialEventKind = "platform-change" | "delay-threshold" | "cancellation" | "disruption";

export interface MaterialEvent {
  kind: MaterialEventKind;
  tripId: string;
  /** Missing on already queued events from before alerts carried an exact service day. */
  serviceDate?: string;
  timingEvent?: "arrival" | "departure";
  stopId: string | null;
  title: string;
  body: string;
  oldValue: string | null;
  newValue: string;
  fingerprint: string;
}

function fingerprint(parts: Array<string | null>): string {
  return createHash("sha256").update(parts.map((part) => part ?? "-").join("|")).digest("hex");
}

function stopKey(stop: StopSnapshot): string {
  return `${stop.sequence}:${stop.stationId}`;
}

function stopMap(snapshot: TripSnapshot): Map<string, StopSnapshot> {
  return new Map(snapshot.stops.map((stop) => [stopKey(stop), stop]));
}

// A realtime platform that disappears (overlay timed out, dropped the stop from its
// window, or suppressed the platform) is unknown, not a change back to the timetable.
// Mirrors the watcher's carry-forward of the last realtime value.
function realtimePlatformLost(oldStop: StopSnapshot, stop: StopSnapshot): boolean {
  if (oldStop.expectedPlatform === null) return false;
  return stop.expectedPlatform === null
    || (oldStop.platformObservedAt !== null && stop.platformObservedAt === null);
}

export function diffSnapshots(
  previous: TripSnapshot | null,
  current: TripSnapshot,
  preferences: PushPreferences,
): MaterialEvent[] {
  if (previous === null) return [];

  const events: MaterialEvent[] = [];
  // Amtrak assignments are tracks, matching the app and the Live Activity.
  const noun = isAmtrakOperated(current) ? "track" : "platform";
  const Noun = noun === "track" ? "Track" : "Platform";
  const previousStops = stopMap(previous);
  const upcomingStops = current.stops.filter((stop) => !stop.passed);
  const wholeTripCancelled = preferences.cancellations
    && upcomingStops.length > 0
    && upcomingStops.every((stop) => stop.cancelled)
    && upcomingStops.some((stop) => previousStops.get(stopKey(stop))?.cancelled === false);

  for (const stop of current.stops) {
    const oldStop = previousStops.get(stopKey(stop));
    if (oldStop === undefined || stop.passed) continue;

    const oldPlatform = oldStop.expectedPlatform ?? oldStop.plannedPlatform;
    const newPlatform = stop.expectedPlatform ?? stop.plannedPlatform;
    if (
      preferences.platformChanges
      && !stop.cancelled
      && newPlatform !== null
      && oldPlatform !== newPlatform
      && !realtimePlatformLost(oldStop, stop)
    ) {
      const assigned = oldPlatform === null;
      events.push({
        kind: "platform-change",
        tripId: current.id,
        stopId: stop.stationId,
        title: assigned ? `${Noun} assigned at ${stop.stationName}` : `${Noun} changed at ${stop.stationName}`,
        body: assigned
          ? `${current.product} departs from ${noun} ${newPlatform}.`
          : `${current.product} now departs from ${noun} ${newPlatform} (was ${oldPlatform}).`,
        oldValue: oldPlatform,
        newValue: newPlatform,
        fingerprint: fingerprint([
          current.id,
          stop.stationId,
          "platform-change",
          oldPlatform,
          newPlatform,
          // Keyed to the snapshot the change was measured from: re-diffing the same pair
          // with a fresher observation time stays one push, while a genuine flip back
          // (measured from a later snapshot) is announced again.
          previous.fetchedAt,
        ]),
      });
    }

    const oldDelay = delayMinutes(oldStop);
    const newDelay = delayMinutes(stop);
    if (
      !stop.cancelled &&
      oldDelay !== null &&
      newDelay !== null &&
      oldDelay < preferences.delayThresholdMinutes &&
      newDelay >= preferences.delayThresholdMinutes
    ) {
      events.push({
        kind: "delay-threshold",
        timingEvent: stop.scheduledDeparture !== null && stop.expectedDeparture !== null ? "departure" : "arrival",
        tripId: current.id,
        stopId: stop.stationId,
        title: `${current.product} is delayed`,
        body: `Expected at ${stop.stationName} ${newDelay} minutes late.`,
        oldValue: String(oldDelay),
        newValue: String(newDelay),
        fingerprint: fingerprint([
          current.id,
          stop.stationId,
          "delay-threshold",
          String(preferences.delayThresholdMinutes),
          String(newDelay),
          current.fetchedAt,
        ]),
      });
    }

    if (preferences.cancellations && !wholeTripCancelled && !oldStop.cancelled && stop.cancelled) {
      events.push({
        kind: "cancellation",
        tripId: current.id,
        stopId: stop.stationId,
        title: `${current.product} cancellation`,
        body: `The call at ${stop.stationName} has been cancelled.`,
        oldValue: "scheduled",
        newValue: "cancelled",
        fingerprint: fingerprint([current.id, stop.stationId, "cancellation", "cancelled", current.fetchedAt]),
      });
    }
  }

  if (wholeTripCancelled) {
    events.push({
      kind: "cancellation",
      tripId: current.id,
      stopId: null,
      title: `${current.product} cancelled`,
      body: `${current.product} has been cancelled.`,
      oldValue: "scheduled",
      newValue: "cancelled",
      fingerprint: fingerprint([current.id, null, "cancellation", "cancelled", current.fetchedAt]),
    });
  }

  if (preferences.disruptions) {
    const previousAlerts = new Set(previous.alertIds);
    for (const alertId of current.alertIds.filter((id) => !previousAlerts.has(id))) {
      events.push({
        kind: "disruption",
        tripId: current.id,
        stopId: null,
        title: `Service update for ${current.product}`,
        body: `A new disruption has been reported for your train.`,
        oldValue: null,
        newValue: alertId,
        fingerprint: fingerprint([current.id, null, "disruption", alertId]),
      });
    }
  }

  return events.map((event) => ({ ...event, serviceDate: current.serviceDate }));
}
