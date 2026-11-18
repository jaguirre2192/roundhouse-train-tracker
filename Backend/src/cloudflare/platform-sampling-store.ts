import type {
  PlatformSampleTarget,
  PlatformSamplingRunReport,
  PlatformSamplingState,
} from "../domain/platform-sampling.js";
import type { CanonicalTripReference } from "../domain/snapshot.js";

interface TargetRow extends Record<string, SqlStorageValue> {
  id: string;
  source: CanonicalTripReference["source"];
  native_id: string;
  service_date: string;
  expires_at: number;
}

interface CountRow extends Record<string, SqlStorageValue> {
  active: number;
  enrolled_today: number;
}

interface StateRow extends Record<string, SqlStorageValue> { value: string }

const discoveryIntervalMilliseconds = 30 * 60_000;
const maximumActiveTargets = 4;
const maximumDailyEnrollments = 4;
const retentionMilliseconds = 400 * 24 * 60 * 60_000;

function message(error: unknown): string {
  return (error instanceof Error ? error.message : String(error)).slice(0, 1_000);
}

export class SQLitePlatformSamplingStore {
  constructor(private readonly sql: SqlStorage) {}

  state(now: number): PlatformSamplingState {
    this.expire(now);
    const startOfDay = Date.parse(new Date(now).toISOString().slice(0, 10));
    const counts = this.sql.exec<CountRow>(
      `SELECT
         (SELECT COUNT(*) FROM platform_sample_trips WHERE status = 'active') AS active,
         (SELECT COUNT(*) FROM platform_sample_trips WHERE created_at >= ?) AS enrolled_today`,
      startOfDay,
    ).one();
    const lastDiscovery = Date.parse(this.runtimeState("platform_sampling_last_discovery_at") ?? "");
    return {
      discoveryDue: !Number.isFinite(lastDiscovery) || now - lastDiscovery >= discoveryIntervalMilliseconds,
      canEnroll: (counts?.active ?? 0) < maximumActiveTargets
        && (counts?.enrolled_today ?? 0) < maximumDailyEnrollments,
    };
  }

  seen(id: string): boolean {
    return this.sql.exec<{ present: number }>(
      "SELECT EXISTS(SELECT 1 FROM platform_sample_trips WHERE id = ?) AS present",
      id,
    ).one().present === 1;
  }

  due(now: number, limit: number): PlatformSampleTarget[] {
    this.expire(now);
    return this.sql.exec<TargetRow>(
      `SELECT id, source, native_id, service_date, expires_at
       FROM platform_sample_trips
       WHERE status = 'active' AND next_poll_at <= ? AND expires_at > ?
       ORDER BY next_poll_at, created_at
       LIMIT ?`,
      now,
      now,
      limit,
    ).toArray().map((row) => ({
      id: row.id,
      source: row.source,
      nativeId: row.native_id,
      serviceDate: row.service_date,
      expiresAt: row.expires_at,
    }));
  }

  enroll(
    reference: CanonicalTripReference,
    departureAt: number,
    enrolledAt: number,
  ): PlatformSampleTarget | null {
    const expiresAt = departureAt + 24 * 60 * 60_000;
    this.sql.exec(
      `INSERT OR IGNORE INTO platform_sample_trips (
         id, source, native_id, service_date, status, next_poll_at, expires_at,
         consecutive_failures, created_at, updated_at
       ) VALUES (?, ?, ?, ?, 'active', ?, ?, 0, ?, ?)`,
      reference.id,
      reference.source,
      reference.nativeId,
      reference.serviceDate,
      enrolledAt,
      expiresAt,
      enrolledAt,
      enrolledAt,
    );
    const row = this.sql.exec<TargetRow>(
      `SELECT id, source, native_id, service_date, expires_at
       FROM platform_sample_trips WHERE id = ? AND status = 'active'`,
      reference.id,
    ).toArray()[0];
    return row === undefined ? null : {
      id: row.id,
      source: row.source,
      nativeId: row.native_id,
      serviceDate: row.service_date,
      expiresAt: row.expires_at,
    };
  }

  succeed(id: string, nextPollAt: number, complete: boolean, recordedAt: number): void {
    this.sql.exec(
      `UPDATE platform_sample_trips SET
         status = ?, next_poll_at = ?, completed_at = ?, consecutive_failures = 0,
         last_error = NULL, updated_at = ?
       WHERE id = ?`,
      complete ? "completed" : "active",
      nextPollAt,
      complete ? recordedAt : null,
      recordedAt,
      id,
    );
  }

  fail(id: string, error: unknown, failedAt: number): void {
    this.sql.exec(
      `UPDATE platform_sample_trips SET
         status = CASE WHEN consecutive_failures + 1 >= 5 THEN 'failed' ELSE status END,
         consecutive_failures = consecutive_failures + 1,
         next_poll_at = ?, last_error = ?, updated_at = ?
       WHERE id = ? AND status = 'active'`,
      failedAt + 30 * 60_000,
      message(error),
      failedAt,
      id,
    );
  }

  recordRun(report: PlatformSamplingRunReport, recordedAt: number): void {
    this.setRuntimeState("platform_sampling_last_run_at", new Date(recordedAt).toISOString(), recordedAt);
    if (report.discoveryAttempted) {
      this.setRuntimeState("platform_sampling_last_discovery_at", new Date(recordedAt).toISOString(), recordedAt);
    }
    if (report.observationsRecorded > 0) {
      this.setRuntimeState("platform_sampling_last_success_at", new Date(recordedAt).toISOString(), recordedAt);
    }
    this.setRuntimeState("platform_sampling_last_report", JSON.stringify(report), recordedAt);
    this.sql.exec(
      "DELETE FROM platform_sample_trips WHERE status != 'active' AND updated_at < ?",
      recordedAt - retentionMilliseconds,
    );
  }

  private expire(now: number): void {
    this.sql.exec(
      `UPDATE platform_sample_trips SET status = 'failed', last_error = 'sample expired', updated_at = ?
       WHERE status = 'active' AND expires_at <= ?`,
      now,
      now,
    );
  }

  private runtimeState(key: string): string | null {
    return this.sql.exec<StateRow>(
      "SELECT value FROM runtime_state WHERE key = ?",
      key,
    ).toArray()[0]?.value ?? null;
  }

  private setRuntimeState(key: string, value: string, now: number): void {
    this.sql.exec(
      `INSERT INTO runtime_state (key, value, updated_at) VALUES (?, ?, ?)
       ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
      key,
      value,
      now,
    );
  }
}
