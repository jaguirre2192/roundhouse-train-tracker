import {
  projectPlatformObservations,
  type CanonicalPlatformObservation,
  type ObservationTrigger,
} from "../domain/platform-observation.js";
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
import { transaction, type DatabaseClient, type DatabasePool } from "./database.js";
import { PostgresPlatformForecastStore } from "./platform-forecast-store.js";
import { shouldRetireTripWatch } from "../domain/trip-watch-recovery.js";
import { equalCredentialHash } from "../auth/device-credential.js";
import { maximumPushAgeMilliseconds, maximumPushAttempts } from "../apns/transport.js";

/// Mirrors the Worker's `MutationDecision` reasons for device mutations.
export type DeviceMutationOutcome =
  | "allowed"
  | "unauthorized"
  | "token_conflict"
  | "quota_exceeded"
  | "trip_conflict";

const activeSubscriptionLimit = 24;

interface DeviceCredentialRow {
  installation_id: string;
  apns_token: string;
  credential_hash: string | null;
}

export class WatcherRepository implements WatcherPersistence {
  private readonly platformForecastStore = new PostgresPlatformForecastStore();

  constructor(private readonly pool: DatabasePool) {}

  async health(): Promise<void> {
    await this.pool.query("SELECT 1");
  }

  /// Registers or refreshes a device. A row is claimable only with its stored
  /// credential (or, for a legacy credential-free row, its own APNs token), and a
  /// token held by another credentialed installation is never taken over.
  async registerDevice(input: DeviceRegistration, credentialHash: string): Promise<DeviceMutationOutcome> {
    return transaction(this.pool, async (client) => {
      const rows = await client.query<DeviceCredentialRow>(
        `SELECT installation_id, apns_token, credential_hash FROM devices
         WHERE installation_id = $1 OR apns_token = $2
         FOR UPDATE`,
        [input.installationId, input.token],
      );
      const byInstallation = rows.rows.find((row) => row.installation_id === input.installationId);
      const byToken = rows.rows.find((row) => row.apns_token === input.token);
      if (byInstallation !== undefined) {
        const claimable = byInstallation.credential_hash === null
          ? byInstallation.apns_token === input.token
          : equalCredentialHash(byInstallation.credential_hash, credentialHash);
        if (!claimable) return "unauthorized";
      }
      if (byToken !== undefined && byToken.installation_id !== input.installationId
        && byToken.credential_hash !== null
        && !equalCredentialHash(byToken.credential_hash, credentialHash)) {
        return "token_conflict";
      }
      await client.query(
        "DELETE FROM devices WHERE apns_token = $1 AND installation_id <> $2",
        [input.token, input.installationId],
      );
      await client.query(
        `INSERT INTO devices (installation_id, apns_token, credential_hash, environment, platform)
         VALUES ($1, $2, $3, $4, $5)
         ON CONFLICT (installation_id) DO UPDATE SET
           apns_token = EXCLUDED.apns_token,
           credential_hash = EXCLUDED.credential_hash,
           environment = EXCLUDED.environment,
           platform = EXCLUDED.platform,
           active = TRUE,
           updated_at = NOW()`,
        [input.installationId, input.token, credentialHash, input.environment, input.platform],
      );
      return "allowed";
    });
  }

  async subscribe(input: SubscriptionInput, credentialHash: string): Promise<DeviceMutationOutcome> {
    const watchId = `${input.trip.id}@${input.trip.serviceDate}`;
    return transaction(this.pool, async (client) => {
      if (!await this.authorized(client, input.installationId, credentialHash)) return "unauthorized";
      const counts = await client.query<{ active: number; already_active: boolean }>(
        `SELECT COUNT(*)::int AS active,
                COALESCE(BOOL_OR(
                  trip_id = $2 AND boarding_station_id = $3 AND alighting_station_id = $4
                ), FALSE) AS already_active
         FROM subscriptions
         WHERE installation_id = $1 AND active = TRUE`,
        [input.installationId, watchId, input.boardingStationId, input.alightingStationId],
      );
      const quota = counts.rows[0];
      if (quota !== undefined && !quota.already_active && quota.active >= activeSubscriptionLimit) {
        return "quota_exceeded";
      }
      // A tracked trip is shared by every subscriber of the same client trip ID;
      // one installation must never repoint what other installations watch.
      const existing = await client.query<{ id: string; source: string; native_id: string }>(
        `SELECT id, source, native_id FROM tracked_trips
         WHERE client_trip_id = $1 AND service_date = $2
         FOR UPDATE`,
        [input.trip.id, input.trip.serviceDate],
      );
      const current = existing.rows[0];
      if (current !== undefined
        && (current.source !== input.trip.source || current.native_id !== input.trip.nativeId)) {
        const others = await client.query(
          `SELECT 1 FROM subscriptions
           WHERE trip_id = $1 AND installation_id <> $2 AND active = TRUE
           LIMIT 1`,
          [current.id, input.installationId],
        );
        if ((others.rowCount ?? 0) > 0) return "trip_conflict";
      }
      const trackedTrip = await client.query<{ id: string }>(
        `INSERT INTO tracked_trips (id, client_trip_id, source, native_id, service_date)
         VALUES ($1, $2, $3, $4, $5)
         ON CONFLICT (client_trip_id, service_date) DO UPDATE SET
           source = EXCLUDED.source,
           native_id = EXCLUDED.native_id,
           -- Never diff snapshots of two different trains.
           latest_snapshot = CASE
             WHEN tracked_trips.source = EXCLUDED.source AND tracked_trips.native_id = EXCLUDED.native_id
               THEN tracked_trips.latest_snapshot
             ELSE NULL
           END,
           consecutive_failures = CASE
             WHEN tracked_trips.source = EXCLUDED.source AND tracked_trips.native_id = EXCLUDED.native_id
               THEN tracked_trips.consecutive_failures
             ELSE 0
           END,
           next_poll_at = LEAST(tracked_trips.next_poll_at, NOW()),
           updated_at = NOW()
         RETURNING tracked_trips.id`,
        [watchId, input.trip.id, input.trip.source, input.trip.nativeId, input.trip.serviceDate],
      );
      const storedTripId = trackedTrip.rows[0]?.id;
      if (storedTripId === undefined) throw new Error("Tracked trip upsert returned no ID");
      await client.query(
        `INSERT INTO subscriptions
           (installation_id, trip_id, boarding_station_id, alighting_station_id, watch_from, preferences)
         VALUES ($1, $2, $3, $4, $5, $6)
         ON CONFLICT (installation_id, trip_id, boarding_station_id, alighting_station_id) DO UPDATE SET
           watch_from = EXCLUDED.watch_from,
           preferences = EXCLUDED.preferences,
           active = TRUE,
           updated_at = NOW()`,
        [
          input.installationId,
          storedTripId,
          input.boardingStationId,
          input.alightingStationId,
          input.watchFrom,
          JSON.stringify(input.preferences),
        ],
      );
      return "allowed";
    });
  }

  async unsubscribe(installationId: string, tripId: string, credentialHash: string): Promise<DeviceMutationOutcome> {
    return transaction(this.pool, async (client) => {
      if (!await this.authorized(client, installationId, credentialHash)) return "unauthorized";
      await client.query(
        `UPDATE subscriptions SET active = FALSE, updated_at = NOW()
         FROM tracked_trips
         WHERE subscriptions.trip_id = tracked_trips.id
           AND subscriptions.installation_id = $1
           AND tracked_trips.client_trip_id = $2`,
        [installationId, tripId],
      );
      return "allowed";
    });
  }

  private async authorized(client: DatabaseClient, installationId: string, credentialHash: string): Promise<boolean> {
    const row = await client.query<{ credential_hash: string | null }>(
      "SELECT credential_hash FROM devices WHERE installation_id = $1",
      [installationId],
    );
    return equalCredentialHash(row.rows[0]?.credential_hash ?? null, credentialHash);
  }

  async claimDueTrips(limit = 10): Promise<ClaimedTrip[]> {
    const result = await this.pool.query<{
      id: string;
      source: CanonicalTripReference["source"];
      native_id: string;
      service_date: string;
      latest_snapshot: TripSnapshot | null;
    }>(
      `WITH due AS (
         SELECT tracked_trips.id
         FROM tracked_trips
         WHERE next_poll_at <= NOW()
           AND (lease_until IS NULL OR lease_until < NOW())
           AND EXISTS (
             SELECT 1 FROM subscriptions
             WHERE subscriptions.trip_id = tracked_trips.id AND subscriptions.active = TRUE
           )
         ORDER BY next_poll_at
         LIMIT $1
         FOR UPDATE SKIP LOCKED
       )
       UPDATE tracked_trips
       SET lease_until = NOW() + INTERVAL '30 seconds', updated_at = NOW()
       FROM due
       WHERE tracked_trips.id = due.id
       RETURNING tracked_trips.id, tracked_trips.source, tracked_trips.native_id,
                 tracked_trips.service_date::text, tracked_trips.latest_snapshot`,
      [limit],
    );
    return result.rows.map((row) => ({
      id: row.id,
      source: row.source,
      nativeId: row.native_id,
      serviceDate: row.service_date,
      latestSnapshot: row.latest_snapshot,
    }));
  }

  async subscriptions(tripId: string): Promise<StoredSubscription[]> {
    const result = await this.pool.query<{
      installation_id: string;
      boarding_station_id: string;
      alighting_station_id: string;
      preferences: Partial<PushPreferences>;
    }>(
      `SELECT installation_id, boarding_station_id, alighting_station_id, preferences
       FROM subscriptions
       WHERE trip_id = $1 AND active = TRUE AND watch_from <= NOW()`,
      [tripId],
    );
    return result.rows.map((row) => ({
      installationId: row.installation_id,
      boardingStationId: row.boarding_station_id,
      alightingStationId: row.alighting_station_id,
      preferences: { ...defaultPushPreferences, ...row.preferences },
    }));
  }

  async recordSuccess(
    tripId: string,
    snapshot: TripSnapshot,
    nextPollSeconds: number,
    targetedEvents: TargetedEvent[],
  ): Promise<void> {
    await transaction(this.pool, async (client) => {
      const forecastedSnapshot = await this.platformForecastStore.forecastSnapshot(
        client,
        snapshot,
        snapshot.fetchedAt,
      );
      await client.query(
        `UPDATE tracked_trips SET
           latest_snapshot = $2,
           next_poll_at = NOW() + ($3 * INTERVAL '1 second'),
           lease_until = NULL,
           consecutive_failures = 0,
           last_error = NULL,
           updated_at = NOW()
         WHERE id = $1`,
        [tripId, JSON.stringify(forecastedSnapshot), nextPollSeconds],
      );
      const observations = projectPlatformObservations(snapshot, "watcher").observations;
      await this.insertPlatformObservations(client, observations);
      await this.platformForecastStore.finalize(client, observations, snapshot.fetchedAt);

      if (shouldRetireTripWatch(snapshot)) {
        await client.query(
          "UPDATE subscriptions SET active = FALSE, updated_at = NOW() WHERE trip_id = $1",
          [tripId],
        );
      }

      for (const targeted of targetedEvents) {
        const event = targeted.event;
        await client.query(
          `INSERT INTO notification_events (fingerprint, trip_id, kind, stop_id, payload)
           VALUES ($1, $2, $3, $4, $5)
           ON CONFLICT (fingerprint) DO NOTHING`,
          [event.fingerprint, tripId, event.kind, event.stopId, JSON.stringify(event)],
        );
        await client.query(
          `INSERT INTO notification_outbox (event_fingerprint, installation_id, payload)
           VALUES ($1, $2, $3)
           ON CONFLICT (event_fingerprint, installation_id) DO NOTHING`,
          [event.fingerprint, targeted.installationId, JSON.stringify(event)],
        );
      }
    });
  }

  async recordPlatformObservations(snapshot: TripSnapshot, trigger: ObservationTrigger): Promise<number> {
    const observations = projectPlatformObservations(snapshot, trigger).observations;
    if (observations.length === 0) return 0;
    await transaction(this.pool, async (client) => {
      await this.insertPlatformObservations(client, observations);
      await this.platformForecastStore.finalize(client, observations, snapshot.fetchedAt);
    });
    return observations.length;
  }

  async forecastPlatformSnapshot(snapshot: TripSnapshot, generatedAt: string): Promise<TripSnapshot> {
    return transaction(this.pool, (client) =>
      this.platformForecastStore.forecastSnapshot(client, snapshot, generatedAt));
  }

  async recordFailure(tripId: string, error: unknown): Promise<void> {
    const message = error instanceof Error ? error.message : String(error);
    await this.pool.query(
      `UPDATE tracked_trips SET
         next_poll_at = NOW() + (LEAST(900, 30 * POWER(2, consecutive_failures)) * INTERVAL '1 second'),
         lease_until = NULL,
         consecutive_failures = consecutive_failures + 1,
         last_error = $2,
         updated_at = NOW()
       WHERE id = $1`,
      [tripId, message.slice(0, 1_000)],
    );
  }

  async claimOutbox(limit = 50): Promise<OutboxMessage[]> {
    const result = await this.pool.query<{
      id: string;
      apns_token: string;
      environment: "sandbox" | "production";
      platform: "ios" | "macos";
      payload: MaterialEvent;
      created_at_ms: number;
    }>(
      `WITH due AS (
         SELECT notification_outbox.id
         FROM notification_outbox
         JOIN devices USING (installation_id)
         WHERE notification_outbox.status IN ('pending', 'sending')
           AND notification_outbox.next_attempt_at <= NOW()
           AND (notification_outbox.lease_until IS NULL OR notification_outbox.lease_until < NOW())
           AND devices.active = TRUE
         ORDER BY notification_outbox.next_attempt_at
         LIMIT $1
         FOR UPDATE OF notification_outbox SKIP LOCKED
       )
       UPDATE notification_outbox
       SET status = 'sending', lease_until = NOW() + INTERVAL '30 seconds', attempts = attempts + 1
       FROM due, devices
       WHERE notification_outbox.id = due.id
         AND devices.installation_id = notification_outbox.installation_id
       RETURNING notification_outbox.id::text, devices.apns_token, devices.environment, devices.platform,
                 notification_outbox.payload,
                 (EXTRACT(EPOCH FROM notification_outbox.created_at) * 1000)::float8 AS created_at_ms`,
      [limit],
    );
    return result.rows.map((row) => ({
      id: row.id,
      token: row.apns_token,
      environment: row.environment,
      platform: row.platform,
      payload: row.payload,
      createdAt: Number(row.created_at_ms),
    }));
  }

  async markDelivered(id: string): Promise<void> {
    await this.pool.query(
      `UPDATE notification_outbox SET status = 'delivered', delivered_at = NOW(), lease_until = NULL
       WHERE id = $1`,
      [id],
    );
  }

  async markDeliveryFailed(id: string, error: unknown, permanent: boolean): Promise<void> {
    const message = error instanceof Error ? error.message : String(error);
    // Permanent errors, an exhausted attempt budget, or a retry that would land
    // after the alert's useful age all end the row.
    await this.pool.query(
      `UPDATE notification_outbox SET
         status = CASE
           WHEN $2::boolean OR attempts >= $4
             OR NOW() + (LEAST(3600, 15 * POWER(2, attempts)) * INTERVAL '1 second')
               > created_at + ($5 * INTERVAL '1 millisecond')
           THEN 'failed' ELSE 'pending'
         END,
         next_attempt_at = NOW() + (LEAST(3600, 15 * POWER(2, attempts)) * INTERVAL '1 second'),
         lease_until = NULL,
         last_error = $3
       WHERE id = $1`,
      [id, permanent, message.slice(0, 1_000), maximumPushAttempts, maximumPushAgeMilliseconds],
    );
  }

  async retireDevice(token: string): Promise<void> {
    await transaction(this.pool, async (client) => {
      await client.query("UPDATE devices SET active = FALSE, updated_at = NOW() WHERE apns_token = $1", [token]);
      await client.query(
        `UPDATE notification_outbox SET status = 'failed', lease_until = NULL, last_error = 'device_retired'
         WHERE status IN ('pending', 'sending')
           AND installation_id IN (SELECT installation_id FROM devices WHERE apns_token = $1)`,
        [token],
      );
    });
  }

  private async insertPlatformObservations(
    client: DatabaseClient,
    observations: CanonicalPlatformObservation[],
  ): Promise<void> {
    for (const observation of observations) {
      await client.query(
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
           $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
           $13, $14, $15, $16, $17, $18, $19, $20, $21, $22, $23, $24,
           $25, $26, $27, $28, $29, $30, $31, $32, $33, $34, $35, $36
         )
         ON CONFLICT (fingerprint) DO UPDATE SET
           first_observed_at = LEAST(platform_observations.first_observed_at, EXCLUDED.first_observed_at),
           last_observed_at = GREATEST(platform_observations.last_observed_at, EXCLUDED.last_observed_at),
           sample_count = platform_observations.sample_count + 1,
           passed = platform_observations.passed OR EXCLUDED.passed,
           platform_observed_at = GREATEST(
             platform_observations.platform_observed_at,
             EXCLUDED.platform_observed_at
           ),
           snapshot_fetched_at = GREATEST(
             platform_observations.snapshot_fetched_at,
             EXCLUDED.snapshot_fetched_at
           ),
           collection_trigger = CASE
             WHEN EXCLUDED.snapshot_fetched_at >= platform_observations.snapshot_fetched_at
               THEN EXCLUDED.collection_trigger
             ELSE platform_observations.collection_trigger
           END,
           payload = CASE
             WHEN EXCLUDED.snapshot_fetched_at >= platform_observations.snapshot_fetched_at
               THEN EXCLUDED.payload
             ELSE platform_observations.payload
           END`,
        [
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
          observation.scheduledArrival,
          observation.scheduledDeparture,
          observation.expectedArrival,
          observation.expectedDeparture,
          observation.plannedPlatform,
          observation.expectedPlatform,
          observation.effectivePlatform,
          observation.platformObservedAt,
          observation.snapshotFetchedAt,
          observation.collectionTrigger,
          observation.firstObservedAt,
          observation.lastObservedAt,
          observation.sampleCount,
          observation.passed,
          observation.cancelled,
          JSON.stringify(observation.payload),
        ],
      );
    }
  }
}
import type { MaterialEvent } from "../domain/events.js";
