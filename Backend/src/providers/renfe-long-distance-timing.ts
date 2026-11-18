import type { TripSnapshot } from "../domain/snapshot.js";
import type { PlatformObservation } from "./platform-overlay.js";
import { matchingRenfeStop, renfeTripID } from "./renfe-service-identity.js";
import { renfeInstant, type RenfeFeed, type RenfeTripUpdate, type RenfeTripUpdateEntity } from "./renfe-realtime-models.js";
import type { RenfeStaticIdentityVerifier } from "./renfe-static-identity.js";

export type RenfeIdentityVerifier = Pick<RenfeStaticIdentityVerifier, "verify">;
export interface VerifiedRenfeUpdate {
  feed: RenfeFeed<RenfeTripUpdateEntity>;
  update: RenfeTripUpdate;
  observedAt: Date;
  delay: number | null;
  cancelled: boolean;
}

/** A bogus -5h47 delay was present in the official feed. Reject, never clamp to on time. */
export function plausibleRenfeDelay(value: unknown): number | null {
  if (value == null || value === "") return null;
  const delay = Number(value);
  return Number.isInteger(delay) && delay >= -300 && delay <= 21_600 ? delay : null;
}

export async function verifiedRenfeUpdate(
  feeds: RenfeFeed<RenfeTripUpdateEntity>[], snapshot: TripSnapshot,
  verifier: RenfeIdentityVerifier, now: Date,
): Promise<VerifiedRenfeUpdate | null> {
  const native = renfeTripID(snapshot);
  const family = /^(\d{5}\d{1,2})\d{4}-\d{2}-\d{2}$/u.exec(native)?.[1];
  if (family === undefined) return null;
  const candidates = feeds.flatMap((feed) => feed.entity.flatMap(({ tripUpdate: update }) => {
    if (update == null || /^(\d{5}\d{1,2})\d{4}-\d{2}-\d{2}$/u.exec(update.trip.tripId)?.[1] !== family) return [];
    return [{ feed, update }];
  }));
  // Conflicting scheduled/cancelled copies cannot be resolved by filtering first.
  const counts = new Map<string, number>();
  for (const { update } of candidates) counts.set(update.trip.tripId, (counts.get(update.trip.tripId) ?? 0) + 1);
  if ([...counts.values()].some((count) => count > 1)) return null;
  const verified: VerifiedRenfeUpdate[] = [];
  for (const { feed, update } of candidates) {
    if (counts.get(update.trip.tripId) !== 1) continue;
    const observedAt = renfeInstant(update.timestamp ?? feed.header.timestamp);
    if (observedAt === null || now.getTime() - observedAt.getTime() > 120_000
      || observedAt.getTime() > now.getTime() + 30_000) continue;
    const relationship = update.trip.scheduleRelationship?.toUpperCase() ?? "SCHEDULED";
    if (!["SCHEDULED", "CANCELED", "DELETED"].includes(relationship)) continue;
    const cancelled = relationship !== "SCHEDULED";
    const delay = plausibleRenfeDelay(update.delay);
    if (!cancelled && delay === null) continue;
    const calls = new Set<number>();
    let ambiguousCall = false;
    for (const call of update.stopTimeUpdate ?? []) {
      const stop = matchingRenfeStop(call.stopId, call.stopSequence, snapshot);
      if (stop === undefined) continue;
      if (calls.has(stop.sequence)) ambiguousCall = true;
      calls.add(stop.sequence);
    }
    if (ambiguousCall) continue;
    if (update.trip.startDate == null) {
      // Check every undated run, including today's future run at midnight while
      // yesterday's train is still operating. The header date is not a run date.
      const times = snapshot.stops.flatMap((stop) => [stop.scheduledArrival, stop.scheduledDeparture])
        .filter((value): value is string => value !== null).map((value) => Date.parse(value) + (delay ?? 0) * 1_000);
      if (times.length < 2 || !times.every(Number.isFinite)
        || Math.max(...times) - Math.min(...times) >= 23 * 3_600_000
        || now.getTime() < Math.min(...times) - 30 * 60_000 || now.getTime() > Math.max(...times) + 15 * 60_000) continue;
    }
    if (await verifier.verify(snapshot, update.trip) === null) continue;
    verified.push({ feed, update, observedAt, delay, cancelled });
  }
  return verified.length === 1 ? verified[0]! : null;
}

/** LD absolute event times describe prior calls under a different clock. Only the
 * independently matched timetable plus the explicit trip delay forms an estimate. */
export function renfeLongDistanceObservations(
  selected: VerifiedRenfeUpdate | null, snapshot: TripSnapshot,
): PlatformObservation[] {
  if (selected === null) return [];
  const { update, delay, cancelled, observedAt } = selected;
  const shifted = (scheduled: string | null) => scheduled === null || delay === null
    ? undefined : new Date(Date.parse(scheduled) + delay * 1_000).toISOString();
  return snapshot.stops.flatMap((stop) => {
    const skipped = (update.stopTimeUpdate ?? []).some((call) =>
      call.scheduleRelationship?.toUpperCase() === "SKIPPED"
      && matchingRenfeStop(call.stopId, call.stopSequence, snapshot)?.sequence === stop.sequence);
    const expectedArrival = shifted(stop.scheduledArrival);
    const expectedDeparture = shifted(stop.scheduledDeparture);
    if (expectedArrival === undefined && expectedDeparture === undefined && !cancelled && !skipped) return [];
    return [{ stopSequence: stop.sequence, stationId: stop.stationId,
      expectedArrival, expectedDeparture, cancelled: cancelled || skipped,
      observedAt: observedAt.toISOString(), source: "Renfe GTFS-RT (reported trip delay)" }];
  });
}
