import {
  projectPlatformObservations,
  type CanonicalPlatformObservation,
  type ObservationTrigger,
} from "../domain/platform-observation.js";
import type { TripSnapshot } from "../domain/snapshot.js";

const retentionMilliseconds = 400 * 24 * 60 * 60 * 1_000;
const pruneStateKey = "platform_observations_last_pruned_day";

function milliseconds(value: string | null): number | null {
  if (value === null) return null;
  const result = Date.parse(value);
  return Number.isFinite(result) ? result : null;
}

export class SQLitePlatformObservationStore {
  constructor(private readonly sql: SqlStorage) {}

  project(snapshot: TripSnapshot, trigger: ObservationTrigger): CanonicalPlatformObservation[] {
    return projectPlatformObservations(snapshot, trigger).observations;
  }

  insert(observations: CanonicalPlatformObservation[]): void {
    for (const observation of observations) {
      this.sql.exec(
        `INSERT INTO platform_observations (
           fingerprint, market, country_code, policy_version,
           source_name, source_license, source_attribution, source_evidence_url,
           trip_id, trip_source, native_trip_id, service_date,
           operator_name, product, headsign, route_signature,
           station_id, station_name, stop_sequence, call_type,
           scheduled_arrival, scheduled_departure,
           expected_arrival, expected_departure,
           planned_platform, expected_platform, effective_platform,
           platform_observed_at, snapshot_fetched_at, collection_trigger,
           first_observed_at, last_observed_at, sample_count,
           passed, cancelled, payload
         ) VALUES (
           ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
           ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
           ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
         )
         ON CONFLICT (fingerprint) DO UPDATE SET
           first_observed_at = MIN(platform_observations.first_observed_at, excluded.first_observed_at),
           last_observed_at = MAX(platform_observations.last_observed_at, excluded.last_observed_at),
           sample_count = platform_observations.sample_count + 1,
           passed = MAX(platform_observations.passed, excluded.passed),
           platform_observed_at = MAX(platform_observations.platform_observed_at, excluded.platform_observed_at),
           snapshot_fetched_at = MAX(platform_observations.snapshot_fetched_at, excluded.snapshot_fetched_at),
           collection_trigger = CASE
             WHEN excluded.snapshot_fetched_at >= platform_observations.snapshot_fetched_at
               THEN excluded.collection_trigger
             ELSE platform_observations.collection_trigger
           END,
           payload = CASE
             WHEN excluded.snapshot_fetched_at >= platform_observations.snapshot_fetched_at
               THEN excluded.payload
             ELSE platform_observations.payload
           END
         WHERE excluded.first_observed_at < platform_observations.first_observed_at
            OR excluded.last_observed_at > platform_observations.last_observed_at
            OR excluded.passed > platform_observations.passed
            OR excluded.platform_observed_at > platform_observations.platform_observed_at
            OR excluded.snapshot_fetched_at > platform_observations.snapshot_fetched_at
            OR (excluded.snapshot_fetched_at >= platform_observations.snapshot_fetched_at
                AND (excluded.collection_trigger != platform_observations.collection_trigger
                     OR excluded.payload != platform_observations.payload))`,
        observation.fingerprint,
        observation.market,
        observation.countryCode,
        observation.policyVersion,
        observation.sourceName,
        observation.sourceLicense,
        observation.sourceAttribution,
        observation.sourceEvidenceURL,
        observation.tripId,
        observation.tripSource,
        observation.nativeTripId,
        observation.serviceDate,
        observation.operatorName,
        observation.product,
        observation.headsign,
        observation.routeSignature,
        observation.stationId,
        observation.stationName,
        observation.stopSequence,
        observation.callType,
        milliseconds(observation.scheduledArrival),
        milliseconds(observation.scheduledDeparture),
        milliseconds(observation.expectedArrival),
        milliseconds(observation.expectedDeparture),
        observation.plannedPlatform,
        observation.expectedPlatform,
        observation.effectivePlatform,
        milliseconds(observation.platformObservedAt) ?? milliseconds(observation.snapshotFetchedAt) ?? Date.now(),
        milliseconds(observation.snapshotFetchedAt) ?? Date.now(),
        observation.collectionTrigger,
        milliseconds(observation.firstObservedAt) ?? Date.now(),
        milliseconds(observation.lastObservedAt) ?? Date.now(),
        observation.sampleCount,
        observation.passed ? 1 : 0,
        observation.cancelled ? 1 : 0,
        JSON.stringify(observation.payload),
      );
    }
  }

  prune(now: number): void {
    const day = new Date(now).toISOString().slice(0, 10);
    const previous = this.sql.exec<{ value: string }>(
      "SELECT value FROM runtime_state WHERE key = ?",
      pruneStateKey,
    ).toArray()[0]?.value;
    if (previous === day) return;
    this.sql.exec(
      "DELETE FROM platform_observations WHERE last_observed_at < ?",
      now - retentionMilliseconds,
    );
    this.sql.exec(
      "DELETE FROM platform_shadow_forecasts WHERE generated_at < ?",
      now - retentionMilliseconds,
    );
    this.sql.exec(
      `INSERT INTO runtime_state (key, value, updated_at) VALUES (?, ?, ?)
       ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
      pruneStateKey,
      day,
      now,
    );
  }
}
