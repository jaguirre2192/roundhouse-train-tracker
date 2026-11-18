import { carryForwardRecoveryPosition } from "../domain/trip-watch-recovery.js";
import { carryForwardPlatforms } from "../domain/platform-continuity.js";
import { pollIntervalSeconds } from "../domain/cadence.js";
import { projectLiveActivity } from "../domain/live-activity-projection.js";
import type { LiveActivityRecord, LiveActivityRegistration, LiveActivitySender } from "../domain/live-activity.js";
import type { CanonicalTripReference, TripSnapshot } from "../domain/snapshot.js";
import type { MutationContext, MutationDecision } from "./mutation-security.js";
import { LiveActivityOutbox } from "./live-activity-outbox.js";
import { LiveActivityStore } from "./live-activity-store.js";

interface TripFetcher { fetchTrip(reference: CanonicalTripReference): Promise<TripSnapshot> }

export class LiveActivityService {
  readonly store: LiveActivityStore;
  private readonly outbox: LiveActivityOutbox;
  private running: Promise<void> | null = null;

  constructor(private readonly storage: DurableObjectStorage, private readonly providers: TripFetcher,
    sender: LiveActivitySender) {
    this.store = new LiveActivityStore(storage);
    this.outbox = new LiveActivityOutbox(storage, this.store, sender);
  }

  register(input: LiveActivityRegistration, context: MutationContext): MutationDecision {
    return this.store.register(input, context);
  }
  stop(installationId: string, activityId: string, context: MutationContext): MutationDecision {
    return this.store.stop(installationId, activityId, context);
  }
  hasWork(): boolean { return this.store.hasWork(); }

  tick(now = Date.now()): Promise<void> {
    if (this.running !== null) return this.running;
    this.running = this.run(now).finally(() => { this.running = null; });
    return this.running;
  }

  private async run(now: number): Promise<void> {
    // Expiration never depends on a responsive rail provider.
    this.store.expire(now);
    await this.outbox.deliver(now);
    const groups = new Map<string, LiveActivityRecord[]>();
    for (const registration of this.store.due(now)) {
      const key = `${registration.trip.source}:${registration.trip.nativeId}:${registration.trip.serviceDate}`;
      const group = groups.get(key) ?? [];
      group.push(registration);
      groups.set(key, group);
    }
    // Bound external work per alarm; all installations following a trip share one provider fetch.
    await Promise.all([...groups.entries()].slice(0, 5).map(async ([key, registrations]) => {
      const registration = registrations[0]!;
      try {
        const cache = this.storage.sql.exec<{ snapshot: string; next_fetch_at: number }>(
          "SELECT snapshot, next_fetch_at FROM live_activity_trip_cache WHERE trip_key = ?", key,
        ).toArray()[0];
        const needsFetch = cache === undefined || cache.next_fetch_at <= now || registrations.some((item) => !item.validated);
        const previous = cache === undefined ? null : JSON.parse(cache.snapshot) as TripSnapshot;
        const snapshot = needsFetch
          ? carryForwardRecoveryPosition(previous,
            carryForwardPlatforms(previous, await this.providers.fetchTrip(registration.trip)), now)
          : previous!;
        const fetchedAt = Date.parse(snapshot.fetchedAt);
        if (snapshot.source !== registration.trip.source || snapshot.nativeId !== registration.trip.nativeId
          || snapshot.serviceDate !== registration.trip.serviceDate || !Number.isFinite(fetchedAt)
          || fetchedAt > now + 60_000) throw new Error("Live Activity snapshot identity is invalid");
        const nextFetch = needsFetch
          ? now + pollIntervalSeconds(registration.trip.source, "full-trip", snapshot, new Date(now)) * 1_000
          : cache.next_fetch_at;
        if (needsFetch) this.storage.sql.exec(`INSERT INTO live_activity_trip_cache (trip_key, snapshot, next_fetch_at, updated_at)
          VALUES (?, ?, ?, ?) ON CONFLICT (trip_key) DO UPDATE SET snapshot = excluded.snapshot,
          next_fetch_at = excluded.next_fetch_at, updated_at = excluded.updated_at`, key, JSON.stringify(snapshot), nextFetch, now);
        for (const item of registrations) {
          const projection = projectLiveActivity({ trip: snapshot, referenceDate: now / 1_000,
            lastSuccessfulCheck: Math.min(fetchedAt, now) / 1_000, refreshFailed: false,
            boardingStationId: item.boardingStationId, alightingStationId: item.alightingStationId,
            boardingStopSequence: item.boardingStopSequence, alightingStopSequence: item.alightingStopSequence,
            stationTimeZones: item.stationTimeZones });
          if (!item.validated && projection.eligibility === "unavailable") {
            this.store.failed(item.activityId, now); continue;
          }
          const invalidStart = !item.validated && projection.eligibility !== "available";
          const nextTransition = projection.nextTransitionDate === null ? Infinity : projection.nextTransitionDate * 1_000;
          this.store.successful(item.activityId, projection.state, invalidStart || projection.shouldEnd,
            Math.max(now + 1_000, Math.min(nextFetch, nextTransition)), now);
        }
      } catch {
        for (const item of registrations) this.store.failed(item.activityId, now);
        console.info("live_activity_poll", { outcome: "retry", registrations: registrations.length });
      }
    }));
    this.storage.sql.exec("DELETE FROM live_activity_trip_cache WHERE updated_at < ?", now - 86_400_000);
    await this.outbox.deliver(now);
  }
}
