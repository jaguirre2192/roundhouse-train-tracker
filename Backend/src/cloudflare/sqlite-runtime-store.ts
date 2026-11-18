import type { WatcherTickReport } from "../worker/watcher-cycle.js";

interface CountRow extends Record<string, SqlStorageValue> { count: number }
interface StateRow extends Record<string, SqlStorageValue> { value: string }

interface TickCheckpoint { at: string; report: WatcherTickReport }
const tickCheckpointKey = "watcher_tick_checkpoint:v2";
const tickCheckpointIntervalMilliseconds = 60_000;

export interface CoordinatorHealth {
  status: "ok";
  devices: number;
  activeSubscriptions: number;
  trackedTrips: number;
  pendingPushes: number;
  platformObservations: number;
  platformObservationSamples: number;
  platformTrainingEvents: number;
  platformObservationSources: number;
  platformObservationLastRecordedAt: string | null;
  platformShadowForecasts: number;
  platformShadowOutcomes: number;
  platformForecastLastGeneratedAt: string | null;
  platformSampleTargetsActive: number;
  platformSampleTargetsCompleted: number;
  platformSampleTargetsFailed: number;
  platformSampleLastRunAt: string | null;
  platformSampleLastSuccessAt: string | null;
  lastTickAt: string | null;
  lastTick: WatcherTickReport | null;
}

export class SQLiteRuntimeStore {
  // A recent health response can report the actual latest tick without rewriting an
  // unchanged diagnostic every 20 seconds. Critical watch/outbox state is stored separately.
  private latestTick: TickCheckpoint | null = null;

  constructor(private readonly sql: SqlStorage) {}

  /// Only watches that have started keep the 20-second alarm hot; a future
  /// watch is woken by `nextWatchStart` instead.
  hasWork(now = Date.now()): boolean {
    const row = this.sql.exec<CountRow>(
      `SELECT
         (SELECT COUNT(*) FROM subscriptions WHERE active = 1 AND watch_from <= ?) +
         (SELECT COUNT(*) FROM notification_outbox
          JOIN devices USING (installation_id)
          WHERE notification_outbox.status IN ('pending', 'sending') AND devices.active = 1) AS count`,
      now,
    ).one();
    return (row?.count ?? 0) > 0;
  }

  nextWatchStart(now = Date.now()): number | null {
    const row = this.sql.exec<{ next: number | null }>(
      "SELECT MIN(watch_from) AS next FROM subscriptions WHERE active = 1 AND watch_from > ?",
      now,
    ).one();
    return row?.next ?? null;
  }

  recordTick(report: WatcherTickReport, now = Date.now()): void {
    const current = { at: new Date(now).toISOString(), report: structuredClone(report) };
    const previous = this.checkpoint();
    const previousAt = previous === null ? NaN : Date.parse(previous.at);
    if (!Number.isFinite(previousAt) || now < previousAt
      || now - previousAt >= tickCheckpointIntervalMilliseconds
      || JSON.stringify(previous?.report) !== JSON.stringify(report)) {
      // Timestamp and report share one atomic row. Never advance the in-memory health
      // observation before a required checkpoint succeeds.
      this.setState(tickCheckpointKey, JSON.stringify(current), now);
    }
    this.latestTick = current;
  }

  health(): CoordinatorHealth {
    const counts = this.sql.exec<{
      devices: number;
      active_subscriptions: number;
      tracked_trips: number;
      pending_pushes: number;
      platform_observations: number;
      platform_observation_samples: number;
      platform_training_events: number;
      platform_observation_sources: number;
      platform_observation_last_recorded_at: number | null;
      platform_shadow_forecasts: number;
      platform_shadow_outcomes: number;
      platform_forecast_last_generated_at: number | null;
      platform_sample_targets_active: number;
      platform_sample_targets_completed: number;
      platform_sample_targets_failed: number;
    }>(
      `SELECT
         (SELECT COUNT(*) FROM devices WHERE active = 1) AS devices,
         (SELECT COUNT(*) FROM subscriptions WHERE active = 1) AS active_subscriptions,
         (SELECT COUNT(*) FROM tracked_trips) AS tracked_trips,
         (SELECT COUNT(*) FROM notification_outbox WHERE status IN ('pending', 'sending')) AS pending_pushes,
         (SELECT COUNT(*) FROM platform_observations) AS platform_observations,
         (SELECT COALESCE(SUM(sample_count), 0) FROM platform_observations) AS platform_observation_samples,
         (SELECT COUNT(*) FROM (
            SELECT 1 FROM platform_observations
            WHERE passed = 1 AND cancelled = 0
            GROUP BY trip_source, native_trip_id, service_date, station_id, stop_sequence
          )) AS platform_training_events,
         (SELECT COUNT(DISTINCT source_name) FROM platform_observations) AS platform_observation_sources,
         (SELECT MAX(last_observed_at) FROM platform_observations) AS platform_observation_last_recorded_at,
         (SELECT COUNT(*) FROM platform_shadow_forecasts) AS platform_shadow_forecasts,
         (SELECT COUNT(*) FROM platform_shadow_forecasts WHERE scored_at IS NOT NULL) AS platform_shadow_outcomes,
         (SELECT MAX(generated_at) FROM platform_shadow_forecasts) AS platform_forecast_last_generated_at,
         (SELECT COUNT(*) FROM platform_sample_trips WHERE status = 'active') AS platform_sample_targets_active,
         (SELECT COUNT(*) FROM platform_sample_trips WHERE status = 'completed') AS platform_sample_targets_completed,
         (SELECT COUNT(*) FROM platform_sample_trips WHERE status = 'failed') AS platform_sample_targets_failed`,
    ).one();
    const tick = this.latestTick ?? this.checkpoint();
    const lastTickAt = tick?.at ?? this.state("last_tick_at");
    const legacyTick = tick === null ? this.state("last_tick") : null;
    return {
      status: "ok",
      devices: counts?.devices ?? 0,
      activeSubscriptions: counts?.active_subscriptions ?? 0,
      trackedTrips: counts?.tracked_trips ?? 0,
      pendingPushes: counts?.pending_pushes ?? 0,
      platformObservations: counts?.platform_observations ?? 0,
      platformObservationSamples: counts?.platform_observation_samples ?? 0,
      platformTrainingEvents: counts?.platform_training_events ?? 0,
      platformObservationSources: counts?.platform_observation_sources ?? 0,
      platformObservationLastRecordedAt: counts?.platform_observation_last_recorded_at === null
        || counts?.platform_observation_last_recorded_at === undefined
        ? null
        : new Date(counts.platform_observation_last_recorded_at).toISOString(),
      platformShadowForecasts: counts?.platform_shadow_forecasts ?? 0,
      platformShadowOutcomes: counts?.platform_shadow_outcomes ?? 0,
      platformForecastLastGeneratedAt: counts?.platform_forecast_last_generated_at === null
        || counts?.platform_forecast_last_generated_at === undefined
        ? null
        : new Date(counts.platform_forecast_last_generated_at).toISOString(),
      platformSampleTargetsActive: counts?.platform_sample_targets_active ?? 0,
      platformSampleTargetsCompleted: counts?.platform_sample_targets_completed ?? 0,
      platformSampleTargetsFailed: counts?.platform_sample_targets_failed ?? 0,
      platformSampleLastRunAt: this.state("platform_sampling_last_run_at"),
      platformSampleLastSuccessAt: this.state("platform_sampling_last_success_at"),
      lastTickAt,
      lastTick: tick === null
        ? (legacyTick === null ? null : JSON.parse(legacyTick) as WatcherTickReport)
        : structuredClone(tick.report),
    };
  }

  private state(key: string): string | null {
    return this.sql.exec<StateRow>("SELECT value FROM runtime_state WHERE key = ?", key).toArray()[0]?.value ?? null;
  }

  private checkpoint(): TickCheckpoint | null {
    const value = this.state(tickCheckpointKey);
    return value === null ? null : JSON.parse(value) as TickCheckpoint;
  }

  private setState(key: string, value: string, now: number): void {
    this.sql.exec(
      `INSERT INTO runtime_state (key, value, updated_at) VALUES (?, ?, ?)
       ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
      key,
      value,
      now,
    );
  }
}
