import type { DeviceRegistration, SubscriptionInput } from "../worker/watcher-persistence.js";
import type { MutationContext, MutationDecision, MutationOperation } from "./mutation-security.js";
import { equalCredential } from "./live-activity-identity.js";

interface DeviceCredentialRow extends Record<string, SqlStorageValue> {
  installation_id: string;
  apns_token: string;
  credential_hash: string | null;
}

interface MutationWindowRow extends Record<string, SqlStorageValue> {
  window_started_at: number;
  request_count: number;
}

const allowed: MutationDecision = { allowed: true };
const mutationWindowMilliseconds = 60_000;
const mutationLimits: Record<MutationOperation, number> = {
  register_device: 10,
  subscribe: 30,
  unsubscribe: 30,
  register_live_activity: 30,
  stop_live_activity: 30,
};
const activeSubscriptionLimit = 24;

function constantTimeEqual(left: string, right: string): boolean {
  const length = Math.max(left.length, right.length);
  let difference = left.length ^ right.length;
  for (let index = 0; index < length; index += 1) {
    difference |= (left.charCodeAt(index) || 0) ^ (right.charCodeAt(index) || 0);
  }
  return difference === 0;
}

export class SQLiteMutationStore {
  constructor(
    private readonly storage: DurableObjectStorage,
    private readonly sql: SqlStorage,
  ) {}

  registerDevice(
    input: DeviceRegistration,
    context: MutationContext,
    now = Date.now(),
  ): MutationDecision {
    let decision: MutationDecision = allowed;
    this.storage.transactionSync(() => {
      decision = this.consumeMutation("register_device", context.clientKey, now);
      if (!decision.allowed) return;

      const activityIdentity = this.sql.exec<{ credential_hash: string }>(
        "SELECT credential_hash FROM live_activity_installations WHERE installation_id = ?", input.installationId,
      ).toArray()[0];
      if (activityIdentity !== undefined && !equalCredential(activityIdentity.credential_hash, context.credentialHash)) {
        decision = { allowed: false, reason: "unauthorized" };
        return;
      }

      const byInstallation = this.device(input.installationId, null);
      const byToken = this.device(null, input.token);
      if (byInstallation !== null && !this.canClaim(byInstallation, input.token, context.credentialHash)) {
        decision = { allowed: false, reason: "unauthorized" };
        return;
      }
      if (byToken !== null && byToken.installation_id !== input.installationId
        && byToken.credential_hash !== null
        && !constantTimeEqual(byToken.credential_hash, context.credentialHash)) {
        decision = { allowed: false, reason: "token_conflict" };
        return;
      }
      this.sql.exec(
        "DELETE FROM devices WHERE apns_token = ? AND installation_id <> ?",
        input.token,
        input.installationId,
      );
      this.sql.exec(
        `INSERT INTO devices
           (installation_id, apns_token, credential_hash, environment, platform, active, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, 1, ?, ?)
         ON CONFLICT (installation_id) DO UPDATE SET
           apns_token = excluded.apns_token,
           credential_hash = excluded.credential_hash,
           environment = excluded.environment,
           platform = excluded.platform,
           active = 1,
           updated_at = excluded.updated_at`,
        input.installationId,
        input.token,
        context.credentialHash,
        input.environment,
        input.platform,
        now,
        now,
      );
    });
    return decision;
  }

  subscribe(input: SubscriptionInput, context: MutationContext, now = Date.now()): MutationDecision {
    const watchId = `${input.trip.id}@${input.trip.serviceDate}`;
    const watchFrom = Date.parse(input.watchFrom);
    let decision: MutationDecision = allowed;
    this.storage.transactionSync(() => {
      decision = this.consumeMutation("subscribe", context.clientKey, now);
      if (!decision.allowed) return;
      if (!this.authorized(input.installationId, context.credentialHash)) {
        decision = { allowed: false, reason: "unauthorized" };
        return;
      }
      const alreadyActive = this.sql.exec<{ found: number }>(
        `SELECT 1 AS found FROM subscriptions
         WHERE installation_id = ? AND trip_id = ?
           AND boarding_station_id = ? AND alighting_station_id = ? AND active = 1
         LIMIT 1`,
        input.installationId,
        watchId,
        input.boardingStationId,
        input.alightingStationId,
      ).toArray().length > 0;
      const activeCount = this.sql.exec<{ count: number }>(
        "SELECT COUNT(*) AS count FROM subscriptions WHERE installation_id = ? AND active = 1",
        input.installationId,
      ).one()?.count ?? 0;
      if (!alreadyActive && activeCount >= activeSubscriptionLimit) {
        decision = { allowed: false, reason: "quota_exceeded" };
        return;
      }
      // A tracked trip is shared by every subscriber of the same client trip ID.
      // One installation must never repoint what other installations watch.
      const existing = this.sql.exec<{ source: string; native_id: string }>(
        "SELECT source, native_id FROM tracked_trips WHERE client_trip_id = ? AND service_date = ?",
        input.trip.id,
        input.trip.serviceDate,
      ).toArray()[0];
      const identityChanged = existing !== undefined
        && (existing.source !== input.trip.source || existing.native_id !== input.trip.nativeId);
      if (identityChanged && this.watchedByOthers(watchId, input.installationId)) {
        decision = { allowed: false, reason: "trip_conflict" };
        return;
      }
      this.sql.exec(
        `INSERT INTO tracked_trips
           (id, client_trip_id, source, native_id, service_date, next_poll_at, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (client_trip_id, service_date) DO UPDATE SET
           source = excluded.source,
           native_id = excluded.native_id,
           -- Never diff snapshots of two different trains.
           latest_snapshot = CASE
             WHEN tracked_trips.source = excluded.source AND tracked_trips.native_id = excluded.native_id
               THEN tracked_trips.latest_snapshot
             ELSE NULL
           END,
           consecutive_failures = CASE
             WHEN tracked_trips.source = excluded.source AND tracked_trips.native_id = excluded.native_id
               THEN tracked_trips.consecutive_failures
             ELSE 0
           END,
           next_poll_at = MIN(tracked_trips.next_poll_at, excluded.next_poll_at),
           updated_at = excluded.updated_at`,
        watchId,
        input.trip.id,
        input.trip.source,
        input.trip.nativeId,
        input.trip.serviceDate,
        now,
        now,
        now,
      );
      this.sql.exec(
        `INSERT INTO subscriptions
           (installation_id, trip_id, boarding_station_id, alighting_station_id,
            watch_from, preferences, active, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
         ON CONFLICT (installation_id, trip_id, boarding_station_id, alighting_station_id) DO UPDATE SET
           watch_from = excluded.watch_from,
           preferences = excluded.preferences,
           active = 1,
           updated_at = excluded.updated_at`,
        input.installationId,
        watchId,
        input.boardingStationId,
        input.alightingStationId,
        watchFrom,
        JSON.stringify(input.preferences),
        now,
        now,
      );
    });
    return decision;
  }

  unsubscribe(
    installationId: string,
    tripId: string,
    context: MutationContext,
    now = Date.now(),
  ): MutationDecision {
    let decision: MutationDecision = allowed;
    this.storage.transactionSync(() => {
      decision = this.consumeMutation("unsubscribe", context.clientKey, now);
      if (!decision.allowed) return;
      if (!this.authorized(installationId, context.credentialHash)) {
        decision = { allowed: false, reason: "unauthorized" };
        return;
      }
      this.sql.exec(
        `UPDATE subscriptions
         SET active = 0, updated_at = ?
         WHERE installation_id = ?
           AND trip_id IN (SELECT id FROM tracked_trips WHERE client_trip_id = ?)`,
        now,
        installationId,
        tripId,
      );
    });
    return decision;
  }

  private watchedByOthers(tripId: string, installationId: string): boolean {
    return this.sql.exec<{ found: number }>(
      `SELECT 1 AS found FROM subscriptions
       WHERE trip_id = ? AND installation_id <> ? AND active = 1
       LIMIT 1`,
      tripId,
      installationId,
    ).toArray().length > 0;
  }

  private device(installationId: string | null, token: string | null): DeviceCredentialRow | null {
    if (installationId !== null) {
      return this.sql.exec<DeviceCredentialRow>(
        "SELECT installation_id, apns_token, credential_hash FROM devices WHERE installation_id = ?",
        installationId,
      ).toArray()[0] ?? null;
    }
    return this.sql.exec<DeviceCredentialRow>(
      "SELECT installation_id, apns_token, credential_hash FROM devices WHERE apns_token = ?",
      token,
    ).toArray()[0] ?? null;
  }

  private canClaim(row: DeviceCredentialRow, token: string, credentialHash: string): boolean {
    if (row.credential_hash === null) return row.apns_token === token;
    return constantTimeEqual(row.credential_hash, credentialHash);
  }

  private authorized(installationId: string, credentialHash: string): boolean {
    const row = this.device(installationId, null);
    return row?.credential_hash !== null && row?.credential_hash !== undefined
      && constantTimeEqual(row.credential_hash, credentialHash);
  }

  private consumeMutation(
    operation: MutationOperation,
    clientKey: string,
    now: number,
  ): MutationDecision {
    const key = `${operation}:${clientKey}`;
    const row = this.sql.exec<MutationWindowRow>(
      "SELECT window_started_at, request_count FROM mutation_rate_windows WHERE key = ?",
      key,
    ).toArray()[0] ?? null;
    if (row === null || now - row.window_started_at >= mutationWindowMilliseconds) {
      this.sql.exec(
        `INSERT INTO mutation_rate_windows (key, window_started_at, request_count, updated_at)
         VALUES (?, ?, 1, ?)
         ON CONFLICT (key) DO UPDATE SET
           window_started_at = excluded.window_started_at,
           request_count = 1,
           updated_at = excluded.updated_at`,
        key,
        now,
        now,
      );
      this.sql.exec("DELETE FROM mutation_rate_windows WHERE updated_at < ?", now - 24 * 60 * 60_000);
      return allowed;
    }
    if (row.request_count >= mutationLimits[operation]) {
      return {
        allowed: false,
        reason: "rate_limited",
        retryAfterSeconds: Math.max(1, Math.ceil(
          (row.window_started_at + mutationWindowMilliseconds - now) / 1_000,
        )),
      };
    }
    this.sql.exec(
      "UPDATE mutation_rate_windows SET request_count = request_count + 1, updated_at = ? WHERE key = ?",
      now,
      key,
    );
    return allowed;
  }
}
