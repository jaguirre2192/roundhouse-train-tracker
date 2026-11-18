import type { MaterialEvent } from "../domain/events.js";
import type { ObservationTrigger } from "../domain/platform-observation.js";
import {
  defaultPushPreferences,
  type CanonicalTripReference,
  type PushPreferences,
  type TripSnapshot,
} from "../domain/snapshot.js";
import type {
  ClaimedTrip,
  DeviceRegistration,
  OutboxMessage,
  StoredSubscription,
  SubscriptionInput,
  TargetedEvent,
  WatcherPersistence,
} from "../worker/watcher-persistence.js";
import type { WatcherTickReport } from "../worker/watcher-cycle.js";
import { SQLitePlatformObservationStore } from "./platform-observation-store.js";
import { SQLitePlatformForecastStore } from "./platform-forecast-store.js";
import {
  type CoordinatorHealth,
  SQLiteRuntimeStore,
} from "./sqlite-runtime-store.js";
import type { MutationContext, MutationDecision } from "./mutation-security.js";
import { SQLiteMutationStore } from "./sqlite-mutation-store.js";
import { SQLitePlatformSamplingStore } from "./platform-sampling-store.js";
import type {
  PlatformCorpusSamplingPersistence,
  PlatformSampleTarget,
  PlatformSamplingRunReport,
  PlatformSamplingState,
} from "../domain/platform-sampling.js";
import { shouldRetireTripWatch } from "../domain/trip-watch-recovery.js";
import {
  maximumPushAgeMilliseconds,
  maximumPushAttempts,
} from "../apns/transport.js";
import { type MaintenanceReport, SQLiteMaintenanceStore } from "./sqlite-maintenance-store.js";

interface TripRow extends Record<string, SqlStorageValue> {
  id: string;
  source: CanonicalTripReference["source"];
  native_id: string;
  service_date: string;
  latest_snapshot: string | null;
}

interface SubscriptionRow extends Record<string, SqlStorageValue> {
  installation_id: string;
  boarding_station_id: string;
  alighting_station_id: string;
  preferences: string;
}

interface OutboxRow extends Record<string, SqlStorageValue> {
  id: number;
  apns_token: string;
  environment: "sandbox" | "production";
  platform: "ios" | "macos";
  payload: string;
  created_at: number;
}

function message(error: unknown): string {
  return (error instanceof Error ? error.message : String(error)).slice(0, 1_000);
}

// Small batches keep each alarm under the Workers subrequest limit; the watcher
// re-arms immediately while a batch comes back full.
export const tripsPerTick = 5;

export class SQLiteWatcherRepository implements WatcherPersistence, PlatformCorpusSamplingPersistence {
  private readonly sql: SqlStorage;
  private readonly mutationStore: SQLiteMutationStore;
  private readonly platformObservationStore: SQLitePlatformObservationStore;
  private readonly platformForecastStore: SQLitePlatformForecastStore;
  private readonly platformSamplingStore: SQLitePlatformSamplingStore;
  private readonly runtimeStore: SQLiteRuntimeStore;
  private readonly maintenanceStore: SQLiteMaintenanceStore;

  constructor(private readonly storage: DurableObjectStorage) {
    this.sql = storage.sql;
    this.mutationStore = new SQLiteMutationStore(storage, this.sql);
    this.platformObservationStore = new SQLitePlatformObservationStore(this.sql);
    this.platformForecastStore = new SQLitePlatformForecastStore(this.sql);
    this.platformSamplingStore = new SQLitePlatformSamplingStore(this.sql);
    this.runtimeStore = new SQLiteRuntimeStore(this.sql);
    this.maintenanceStore = new SQLiteMaintenanceStore(storage, this.sql);
  }

  registerDevice(
    input: DeviceRegistration,
    context: MutationContext,
    now = Date.now(),
  ): MutationDecision {
    return this.mutationStore.registerDevice(input, context, now);
  }

  subscribe(input: SubscriptionInput, context: MutationContext, now = Date.now()): MutationDecision {
    return this.mutationStore.subscribe(input, context, now);
  }

  unsubscribe(
    installationId: string,
    tripId: string,
    context: MutationContext,
    now = Date.now(),
  ): MutationDecision {
    return this.mutationStore.unsubscribe(installationId, tripId, context, now);
  }

  async claimDueTrips(limit = tripsPerTick): Promise<ClaimedTrip[]> {
    const rows: ClaimedTrip[] = [];
    const cursor = this.sql.exec<TripRow>(
      `SELECT id, source, native_id, service_date, latest_snapshot
       FROM tracked_trips
       WHERE next_poll_at <= ?
         AND EXISTS (
           SELECT 1 FROM subscriptions
           WHERE subscriptions.trip_id = tracked_trips.id
             AND subscriptions.active = 1
             AND subscriptions.watch_from <= ?
         )
       ORDER BY next_poll_at
       LIMIT ?`,
      Date.now(),
      Date.now(),
      limit,
    );
    for (const row of cursor) {
      rows.push({
        id: row.id,
        source: row.source,
        nativeId: row.native_id,
        serviceDate: row.service_date,
        latestSnapshot: row.latest_snapshot === null
          ? null
          : JSON.parse(row.latest_snapshot) as TripSnapshot,
      });
    }
    return rows;
  }

  async subscriptions(tripId: string): Promise<StoredSubscription[]> {
    const rows = this.sql.exec<SubscriptionRow>(
      `SELECT installation_id, boarding_station_id, alighting_station_id, preferences
       FROM subscriptions
       WHERE trip_id = ? AND active = 1 AND watch_from <= ?`,
      tripId,
      Date.now(),
    ).toArray();
    return rows.map((row) => ({
      installationId: row.installation_id,
      boardingStationId: row.boarding_station_id,
      alightingStationId: row.alighting_station_id,
      preferences: {
        ...defaultPushPreferences,
        ...JSON.parse(row.preferences) as Partial<PushPreferences>,
      },
    }));
  }

  async recordSuccess(
    tripId: string,
    snapshot: TripSnapshot,
    nextPollSeconds: number,
    targetedEvents: TargetedEvent[],
  ): Promise<void> {
    const now = Date.now();
    this.storage.transactionSync(() => {
      const forecastedSnapshot = this.platformForecastStore.forecastSnapshot(snapshot, snapshot.fetchedAt);
      const observations = this.platformObservationStore.project(snapshot, "watcher");
      this.sql.exec(
        `UPDATE tracked_trips SET
           latest_snapshot = ?,
           next_poll_at = ?,
           consecutive_failures = 0,
           last_error = NULL,
           updated_at = ?
         WHERE id = ?`,
        JSON.stringify(forecastedSnapshot),
        now + nextPollSeconds * 1_000,
        now,
        tripId,
      );
      this.platformObservationStore.insert(observations);
      this.platformForecastStore.finalize(observations, snapshot.fetchedAt);
      this.platformObservationStore.prune(now);

      if (shouldRetireTripWatch(snapshot, now)) {
        this.sql.exec("UPDATE subscriptions SET active = 0, updated_at = ? WHERE trip_id = ?", now, tripId);
      }

      for (const targeted of targetedEvents) {
        const event = targeted.event;
        this.sql.exec(
          `INSERT OR IGNORE INTO notification_events
             (fingerprint, trip_id, kind, stop_id, payload, created_at)
           VALUES (?, ?, ?, ?, ?, ?)`,
          event.fingerprint,
          tripId,
          event.kind,
          event.stopId,
          JSON.stringify(event),
          now,
        );
        this.sql.exec(
          `INSERT OR IGNORE INTO notification_outbox
             (event_fingerprint, installation_id, payload, status, attempts, next_attempt_at, created_at)
           VALUES (?, ?, ?, 'pending', 0, ?, ?)`,
          event.fingerprint,
          targeted.installationId,
          JSON.stringify(event),
          now,
          now,
        );
      }
    });
  }

  recordPlatformObservations(snapshot: TripSnapshot, trigger: ObservationTrigger): number {
    const observations = this.platformObservationStore.project(snapshot, trigger);
    if (observations.length === 0) return 0;
    this.storage.transactionSync(() => {
      this.platformObservationStore.insert(observations);
      this.platformForecastStore.finalize(observations, snapshot.fetchedAt);
      this.platformObservationStore.prune(Date.now());
    });
    return observations.length;
  }

  forecastPlatformSnapshot(snapshot: TripSnapshot, generatedAt: string): TripSnapshot {
    return this.storage.transactionSync(() =>
      this.platformForecastStore.forecastSnapshot(snapshot, generatedAt));
  }

  samplingState(now: number): PlatformSamplingState {
    return this.platformSamplingStore.state(now);
  }

  platformSampleSeen(id: string): boolean {
    return this.platformSamplingStore.seen(id);
  }

  duePlatformSamples(now: number, limit = 4): PlatformSampleTarget[] {
    return this.platformSamplingStore.due(now, limit);
  }

  enrollPlatformSample(
    reference: CanonicalTripReference,
    departureAt: number,
    enrolledAt: number,
  ): PlatformSampleTarget | null {
    return this.platformSamplingStore.enroll(reference, departureAt, enrolledAt);
  }

  recordPlatformSampleSuccess(
    target: PlatformSampleTarget,
    snapshot: TripSnapshot,
    nextPollAt: number,
    complete: boolean,
    recordedAt: number,
  ): number {
    const observations = this.platformObservationStore.project(snapshot, "watcher");
    this.storage.transactionSync(() => {
      this.platformForecastStore.forecastSnapshot(snapshot, snapshot.fetchedAt);
      this.platformObservationStore.insert(observations);
      this.platformForecastStore.finalize(observations, snapshot.fetchedAt);
      this.platformSamplingStore.succeed(target.id, nextPollAt, complete, recordedAt);
      this.platformObservationStore.prune(recordedAt);
    });
    return observations.length;
  }

  recordPlatformSampleFailure(target: PlatformSampleTarget, error: unknown, failedAt: number): void {
    this.platformSamplingStore.fail(target.id, error, failedAt);
  }

  recordPlatformSamplingRun(report: PlatformSamplingRunReport, recordedAt: number): void {
    this.platformSamplingStore.recordRun(report, recordedAt);
  }

  async recordFailure(tripId: string, error: unknown, now = Date.now()): Promise<void> {
    const row = this.sql.exec<{ consecutive_failures: number }>(
      "SELECT consecutive_failures FROM tracked_trips WHERE id = ?",
      tripId,
    ).toArray()[0];
    const failures = row?.consecutive_failures ?? 0;
    const backoffSeconds = Math.min(900, 30 * 2 ** failures);
    this.sql.exec(
      `UPDATE tracked_trips SET
         next_poll_at = ?,
         consecutive_failures = consecutive_failures + 1,
         last_error = ?,
         updated_at = ?
       WHERE id = ?`,
      now + backoffSeconds * 1_000,
      message(error),
      now,
      tripId,
    );
    this.maintenanceStore.retireTripIfStale(tripId, now);
  }

  async claimOutbox(limit = 20): Promise<OutboxMessage[]> {
    const now = Date.now();
    return this.storage.transactionSync(() => {
      const rows = this.sql.exec<OutboxRow>(
        `SELECT notification_outbox.id, devices.apns_token, devices.environment,
                devices.platform, notification_outbox.payload, notification_outbox.created_at
         FROM notification_outbox
         JOIN devices USING (installation_id)
         WHERE notification_outbox.status IN ('pending', 'sending')
           AND notification_outbox.next_attempt_at <= ?
           AND devices.active = 1
         ORDER BY notification_outbox.next_attempt_at
         LIMIT ?`,
        now,
        limit,
      ).toArray();
      for (const row of rows) {
        this.sql.exec(
          `UPDATE notification_outbox
           SET status = 'sending', attempts = attempts + 1, next_attempt_at = ?
           WHERE id = ?`,
          now + 30_000,
          row.id,
        );
      }
      return rows.map((row) => ({
        id: String(row.id),
        token: row.apns_token,
        environment: row.environment,
        platform: row.platform,
        payload: JSON.parse(row.payload) as MaterialEvent,
        createdAt: row.created_at,
      }));
    });
  }

  async markDelivered(id: string): Promise<void> {
    this.sql.exec(
      `UPDATE notification_outbox
       SET status = 'delivered', delivered_at = ?, last_error = NULL
       WHERE id = ?`,
      Date.now(),
      Number(id),
    );
  }

  async markDeliveryFailed(id: string, error: unknown, permanent: boolean, now = Date.now()): Promise<void> {
    const row = this.sql.exec<{ attempts: number; created_at: number }>(
      "SELECT attempts, created_at FROM notification_outbox WHERE id = ?",
      Number(id),
    ).toArray()[0];
    const attempts = row?.attempts ?? 1;
    const backoffSeconds = Math.min(3_600, 15 * 2 ** attempts);
    const nextAttemptAt = now + backoffSeconds * 1_000;
    const exhausted = attempts >= maximumPushAttempts
      || (row !== undefined && nextAttemptAt - row.created_at > maximumPushAgeMilliseconds);
    this.sql.exec(
      `UPDATE notification_outbox
       SET status = ?, next_attempt_at = ?, last_error = ?
       WHERE id = ?`,
      permanent || exhausted ? "failed" : "pending",
      nextAttemptAt,
      message(error),
      Number(id),
    );
  }

  async retireDevice(token: string, now = Date.now()): Promise<void> {
    this.storage.transactionSync(() => {
      this.sql.exec("UPDATE devices SET active = 0, updated_at = ? WHERE apns_token = ?", now, token);
      this.sql.exec(
        `UPDATE notification_outbox
         SET status = 'failed', last_error = 'device_retired'
         WHERE status IN ('pending', 'sending')
           AND installation_id IN (SELECT installation_id FROM devices WHERE apns_token = ?)`,
        token,
      );
    });
  }

  hasWork(now = Date.now()): boolean {
    return this.runtimeStore.hasWork(now);
  }

  /// Earliest future watch start, used to park the alarm until a watch begins.
  nextWatchStart(now = Date.now()): number | null {
    return this.runtimeStore.nextWatchStart(now);
  }

  maintain(now = Date.now()): MaintenanceReport {
    return this.maintenanceStore.prune(now);
  }

  recordTick(report: WatcherTickReport, now = Date.now()): void {
    this.runtimeStore.recordTick(report, now);
  }

  health(): CoordinatorHealth {
    return this.runtimeStore.health();
  }
}
