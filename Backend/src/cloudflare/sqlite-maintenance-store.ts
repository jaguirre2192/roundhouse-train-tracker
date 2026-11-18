import type { TripSnapshot } from "../domain/snapshot.js";
import { shouldRetireTripWatch } from "../domain/trip-watch-recovery.js";

const dayMilliseconds = 24 * 60 * 60_000;

/// A watch whose trip fetch keeps failing is retired once its service date is
/// this far behind, so it stops holding quota and keeping the alarm hot.
export const staleWatchServiceDays = 2;
/// Independent of the service date, a watch that has failed this many times in a
/// row (about two days at the 15-minute backoff cap) is retired.
export const maximumConsecutiveTripFailures = 192;

export const retention = {
  outboxDays: 7,
  eventDays: 14,
  trackedTripServiceDays: 3,
  inactiveDeviceDays: 30,
} as const;

/// Rows removed per table per alarm. Small batches keep each alarm short.
export const pruneBatchSize = 100;

export interface MaintenanceReport {
  retiredSubscriptions: number;
  prunedOutbox: number;
  prunedEvents: number;
  prunedTrips: number;
  prunedDevices: number;
  prunedSessions: number;
  prunedAuthCodes: number;
}

export function isoDateBefore(now: number, days: number): string {
  return new Date(now - days * dayMilliseconds).toISOString().slice(0, 10);
}

interface IdRow extends Record<string, SqlStorageValue> { id: string }
interface StaleTripRow extends IdRow {
  latest_snapshot: string | null;
  consecutive_failures: number;
}

export class SQLiteMaintenanceStore {
  constructor(
    private readonly storage: DurableObjectStorage,
    private readonly sql: SqlStorage,
  ) {}

  /// An old service date can still belong to an active multi-day train. Consult
  /// its last useful snapshot before an outage is allowed to retire the watch.
  retireStaleWatches(now: number): number {
    const rows = this.sql.exec<StaleTripRow>(
      `SELECT id, latest_snapshot, consecutive_failures FROM tracked_trips
       WHERE ((service_date < ? AND (latest_snapshot IS NULL OR consecutive_failures > 0))
          OR consecutive_failures >= ?)
         AND EXISTS (SELECT 1 FROM subscriptions WHERE trip_id = tracked_trips.id AND active = 1)`,
      isoDateBefore(now, staleWatchServiceDays), maximumConsecutiveTripFailures,
    ).toArray();
    return rows.reduce((count, row) => count + this.retireIfExpired(row, now), 0);
  }

  retireTripIfStale(tripId: string, now: number): void {
    const row = this.sql.exec<StaleTripRow>(
      `SELECT id, latest_snapshot, consecutive_failures FROM tracked_trips
       WHERE id = ? AND (service_date < ? OR consecutive_failures >= ?)`,
      tripId, isoDateBefore(now, staleWatchServiceDays), maximumConsecutiveTripFailures,
    ).toArray()[0];
    if (row !== undefined) this.retireIfExpired(row, now);
  }

  private retireIfExpired(row: StaleTripRow, now: number): number {
    if (row.consecutive_failures < maximumConsecutiveTripFailures && row.latest_snapshot !== null) {
      try {
        const snapshot = JSON.parse(row.latest_snapshot) as TripSnapshot;
        if (!shouldRetireTripWatch(snapshot, now)) return 0;
      } catch { /* Invalid retained data cannot keep a failed watch alive indefinitely. */ }
    }
    return this.sql.exec(
      "UPDATE subscriptions SET active = 0, updated_at = ? WHERE active = 1 AND trip_id = ?",
      now, row.id,
    ).rowsWritten;
  }

  prune(now: number, batchSize = pruneBatchSize): MaintenanceReport {
    return this.storage.transactionSync(() => {
      const retiredSubscriptions = this.retireStaleWatches(now);
      const prunedOutbox = this.sql.exec(
        `DELETE FROM notification_outbox WHERE id IN (
           SELECT id FROM notification_outbox
           WHERE status IN ('delivered', 'failed') AND created_at < ?
           LIMIT ?
         )`,
        now - retention.outboxDays * dayMilliseconds,
        batchSize,
      ).rowsWritten;

      const staleEvents = this.sql.exec<{ fingerprint: string }>(
        "SELECT fingerprint FROM notification_events WHERE created_at < ? LIMIT ?",
        now - retention.eventDays * dayMilliseconds,
        batchSize,
      ).toArray().map((row) => row.fingerprint);
      for (const fingerprint of staleEvents) {
        this.sql.exec("DELETE FROM notification_outbox WHERE event_fingerprint = ?", fingerprint);
        this.sql.exec("DELETE FROM notification_events WHERE fingerprint = ?", fingerprint);
      }

      // Trips still carrying an active watch (a multi-day service) are kept.
      const staleTrips = this.sql.exec<IdRow>(
        `SELECT id FROM tracked_trips
         WHERE service_date < ?
           AND NOT EXISTS (
             SELECT 1 FROM subscriptions
             WHERE subscriptions.trip_id = tracked_trips.id AND subscriptions.active = 1
           )
         LIMIT ?`,
        isoDateBefore(now, retention.trackedTripServiceDays),
        batchSize,
      ).toArray().map((row) => row.id);
      for (const id of staleTrips) {
        this.sql.exec(
          `DELETE FROM notification_outbox WHERE event_fingerprint IN (
             SELECT fingerprint FROM notification_events WHERE trip_id = ?
           )`,
          id,
        );
        this.sql.exec("DELETE FROM notification_events WHERE trip_id = ?", id);
        this.sql.exec("DELETE FROM subscriptions WHERE trip_id = ?", id);
        this.sql.exec("DELETE FROM tracked_trips WHERE id = ?", id);
      }

      const staleDevices = this.sql.exec<{ installation_id: string }>(
        "SELECT installation_id FROM devices WHERE active = 0 AND updated_at < ? LIMIT ?",
        now - retention.inactiveDeviceDays * dayMilliseconds,
        batchSize,
      ).toArray().map((row) => row.installation_id);
      for (const installationId of staleDevices) {
        this.sql.exec("DELETE FROM notification_outbox WHERE installation_id = ?", installationId);
        this.sql.exec("DELETE FROM subscriptions WHERE installation_id = ?", installationId);
        this.sql.exec("DELETE FROM devices WHERE installation_id = ?", installationId);
      }

      const prunedSessions = this.sql.exec(
        `DELETE FROM app_sessions WHERE token_hash IN (
           SELECT token_hash FROM app_sessions WHERE expires_at < ? LIMIT ?
         )`,
        now,
        batchSize,
      ).rowsWritten;
      const prunedExchangeCodes = this.sql.exec(
        `DELETE FROM auth_exchange_codes WHERE code_hash IN (
           SELECT code_hash FROM auth_exchange_codes WHERE expires_at < ? LIMIT ?
         )`,
        now,
        batchSize,
      ).rowsWritten;
      const prunedGoogleStates = this.sql.exec(
        `DELETE FROM auth_google_states WHERE state_hash IN (
           SELECT state_hash FROM auth_google_states WHERE expires_at < ? LIMIT ?
         )`,
        now,
        batchSize,
      ).rowsWritten;

      return {
        retiredSubscriptions,
        prunedOutbox,
        prunedEvents: staleEvents.length,
        prunedTrips: staleTrips.length,
        prunedDevices: staleDevices.length,
        prunedSessions,
        prunedAuthCodes: prunedExchangeCodes + prunedGoogleStates,
      };
    });
  }
}
