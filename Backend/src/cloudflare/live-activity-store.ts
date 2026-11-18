import { preserveBoardingPlatform } from "../domain/live-activity-platform-continuity.js";
import { hasActionableBoardingPlatform, liveActivityAlert, liveActivityEndDeliveryLifetime, liveActivityMaximumLifetime,
  type LiveActivityAlert, type LiveActivityContentState, type LiveActivityPush, type LiveActivityRecord,
  type LiveActivityRegistration } from "../domain/live-activity.js";
import type { MutationContext, MutationDecision } from "./mutation-security.js";
import { authorizeLiveActivity } from "./live-activity-identity.js";

interface Row extends Record<string, SqlStorageValue> {
  activity_id: string; registration: string; token: string; token_generation: number;
  status: LiveActivityRecord["status"]; validated: number; content: string; expires_at: number;
  failures: number; revision: number; last_timestamp: number;
}
const conflict: MutationDecision = { allowed: false, reason: "token_conflict" };

export class LiveActivityStore {
  private readonly sql: SqlStorage;
  constructor(private readonly storage: DurableObjectStorage) { this.sql = storage.sql; }

  get(activityId: string): LiveActivityRecord | null {
    const row = this.row(activityId);
    return row === undefined ? null : this.decode(row);
  }

  register(input: LiveActivityRegistration, context: MutationContext, now = Date.now()): MutationDecision {
    let decision: MutationDecision = { allowed: true };
    this.storage.transactionSync(() => {
      decision = authorizeLiveActivity(this.sql, input.installationId, context, "register_live_activity", now);
      if (!decision.allowed) return;
      const current = this.get(input.activityId);
      if (this.sql.exec("SELECT 1 FROM live_activity_stops WHERE activity_id = ? AND installation_id = ?",
        input.activityId, input.installationId).toArray().length > 0) { decision = conflict; return; }
      if (current !== null) {
        if (current.status !== "active" || current.expiresAt <= now || !this.sameSelection(current, input)) {
          decision = conflict; return;
        }
        if (input.tokenGeneration < current.tokenGeneration) return;
        if (input.tokenGeneration === current.tokenGeneration) {
          if (input.token !== current.token) decision = conflict;
          return;
        }
      } else if (Date.parse(input.startedAt) > now + 60_000
        || Date.parse(input.startedAt) + liveActivityMaximumLifetime <= now) { decision = conflict; return; }

      const otherToken = this.sql.exec("SELECT 1 FROM live_activities WHERE token = ? AND activity_id <> ? AND status <> 'ended'",
        input.token, input.activityId).toArray().length > 0;
      if (otherToken) { decision = conflict; return; }
      const otherActivity = this.sql.exec("SELECT 1 FROM live_activities WHERE installation_id = ? AND activity_id <> ? AND status = 'active'",
        input.installationId, input.activityId).toArray().length > 0;
      if (otherActivity) { decision = { allowed: false, reason: "quota_exceeded" }; return; }

      if (current === null) {
        const { token: _token, ...registration } = input;
        this.sql.exec(`INSERT INTO live_activities
          (activity_id, installation_id, registration, token, token_generation, status, content,
           expires_at, next_poll_at, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?)`, input.activityId, input.installationId,
        JSON.stringify(registration), input.token, input.tokenGeneration, JSON.stringify(input.initialContentState),
        Date.parse(input.startedAt) + liveActivityMaximumLifetime, now, now, now);
      } else {
        this.sql.exec("UPDATE live_activities SET token = ?, token_generation = ?, next_poll_at = ?, updated_at = ? WHERE activity_id = ?",
          input.token, input.tokenGeneration, now, now, input.activityId);
        // A successful snapshot is replayed to the replacement token. Never reuse a queued old-token payload.
        this.sql.exec("DELETE FROM live_activity_outbox WHERE activity_id = ?", input.activityId);
        if (current.validated) this.queue(input.activityId, current.content, "update", now);
      }
    });
    return decision;
  }

  stop(installationId: string, activityId: string, context: MutationContext, now = Date.now()): MutationDecision {
    let decision: MutationDecision = { allowed: true };
    this.storage.transactionSync(() => {
      decision = authorizeLiveActivity(this.sql, installationId, context, "stop_live_activity", now);
      if (!decision.allowed) return;
      const current = this.get(activityId);
      if (current !== null && current.installationId !== installationId) { decision = { allowed: false, reason: "unauthorized" }; return; }
      // Also protects a stop arriving before an earlier, delayed registration request.
      this.sql.exec("INSERT OR IGNORE INTO live_activity_stops (activity_id, installation_id, stopped_at) VALUES (?, ?, ?)",
        activityId, installationId, now);
      if (current?.status === "active") this.queue(activityId, current.content, "end", now);
    });
    return decision;
  }

  due(now: number, limit = 100): LiveActivityRecord[] {
    return this.sql.exec<Row>("SELECT * FROM live_activities WHERE status = 'active' AND next_poll_at <= ? ORDER BY next_poll_at LIMIT ?",
      now, limit).toArray().map((row) => this.decode(row));
  }

  successful(activityId: string, content: LiveActivityContentState, shouldEnd: boolean, nextPollAt: number, now: number): void {
    this.storage.transactionSync(() => {
      const current = this.get(activityId);
      if (current?.status !== "active") return;
      content = preserveBoardingPlatform(current.content, content);
      this.sql.exec("UPDATE live_activities SET validated = 1, failures = 0, next_poll_at = ?, updated_at = ? WHERE activity_id = ?",
        nextPollAt, now, activityId);
      // Repeated equal snapshots still renew checkedAt, but no push is needed inside the same check instant.
      if (shouldEnd || JSON.stringify(current.content) !== JSON.stringify(content)) {
        const alert = shouldEnd ? null : liveActivityAlert(current.content, content, current, now / 1_000);
        this.queue(activityId, content, shouldEnd ? "end" : "update", now, alert ?? undefined);
      }
    });
  }

  failed(activityId: string, now: number): void {
    const current = this.get(activityId);
    if (current?.status !== "active") return;
    const delay = Math.min(300_000, 30_000 * 2 ** Math.min(current.failures, 4));
    this.sql.exec("UPDATE live_activities SET failures = failures + 1, next_poll_at = ?, updated_at = ? WHERE activity_id = ? AND status = 'active'",
      now + delay, now, activityId);
    // Keep the last successful payload and stale-date. A failed fetch is not a new check.
  }

  expire(now: number): void {
    this.storage.transactionSync(() => {
      for (const row of this.sql.exec<Row>("SELECT * FROM live_activities WHERE status = 'active' AND expires_at <= ?", now).toArray()) {
        const content = JSON.parse(row.content) as LiveActivityContentState;
        this.queue(row.activity_id, { ...content, phase: "unavailable", focusName: "Journey details unavailable",
          eventTime: null, timingBasis: "unavailable", platform: null, platformBasis: "unavailable",
          platformChanged: false, delayMinutes: null, isStopCancelled: false,
          validUntil: Math.min(content.validUntil, now / 1_000) }, "end", now);
      }
      for (const row of this.sql.exec<{ activity_id: string }>("SELECT activity_id FROM live_activity_outbox WHERE expires_at <= ?", now).toArray()) {
        const current = this.get(row.activity_id);
        if (current?.status === "ending") this.retire(row.activity_id, current.tokenGeneration, now);
        else this.sql.exec("DELETE FROM live_activity_outbox WHERE activity_id = ?", row.activity_id);
      }
      this.sql.exec("DELETE FROM live_activities WHERE status = 'ended' AND updated_at < ?", now - 7 * 86_400_000);
      this.sql.exec("DELETE FROM live_activity_stops WHERE stopped_at < ?", now - 7 * 86_400_000);
    });
  }

  hasWork(): boolean {
    return this.sql.exec("SELECT 1 FROM live_activities WHERE status IN ('active', 'ending') LIMIT 1").toArray().length > 0;
  }

  retire(activityId: string, generation: number, now: number): void {
    this.storage.transactionSync(() => {
      const current = this.get(activityId);
      if (current === null || current.tokenGeneration !== generation) return;
      this.sql.exec("UPDATE live_activities SET status = 'ended', token = '', updated_at = ? WHERE activity_id = ?", now, activityId);
      this.sql.exec("DELETE FROM live_activity_outbox WHERE activity_id = ?", activityId);
    });
  }

  private queue(activityId: string, content: LiveActivityContentState, event: "update" | "end", now: number,
    alert?: LiveActivityAlert): void {
    const row = this.row(activityId);
    if (row === undefined || row.status !== "active") return;
    const registration = this.decode(row);
    // An unsent alert survives a quieter follow-up while the announced assignment still holds.
    const pending = this.sql.exec<{ payload: string }>("SELECT payload FROM live_activity_outbox WHERE activity_id = ?", activityId)
      .toArray()[0];
    if (alert === undefined && event === "update" && pending !== undefined) {
      const previous = JSON.parse(pending.payload) as LiveActivityPush;
      if (previous.alert !== undefined && previous.content.platform === content.platform
        && previous.content.focusName === content.focusName
        && previous.content.boardingPlatformSequence === content.boardingPlatformSequence
        && hasActionableBoardingPlatform(content, registration, now / 1_000)) alert = previous.alert;
    }
    const revision = row.revision + 1;
    const timestamp = Math.max(Math.floor(now / 1_000), row.last_timestamp + 1);
    const expiresAt = event === "end" ? now + liveActivityEndDeliveryLifetime : row.expires_at;
    const payload: LiveActivityPush = { activityId, token: row.token, tokenGeneration: row.token_generation,
      environment: registration.environment, revision, timestamp, event, content, expiresAt,
      ...(alert === undefined ? {} : { alert }) };
    this.sql.exec("UPDATE live_activities SET content = ?, status = ?, revision = ?, last_timestamp = ?, updated_at = ? WHERE activity_id = ?",
      JSON.stringify(content), event === "end" ? "ending" : "active", revision, timestamp, now, activityId);
    this.sql.exec(`INSERT INTO live_activity_outbox
      (activity_id, payload, revision, token_generation, next_attempt_at, expires_at)
      VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (activity_id) DO UPDATE SET
      payload = excluded.payload, revision = excluded.revision, token_generation = excluded.token_generation,
      attempts = 0, next_attempt_at = excluded.next_attempt_at, lease_until = 0, expires_at = excluded.expires_at`,
    activityId, JSON.stringify(payload), revision, row.token_generation, now, expiresAt);
  }

  private row(activityId: string): Row | undefined {
    return this.sql.exec<Row>("SELECT * FROM live_activities WHERE activity_id = ?", activityId).toArray()[0];
  }

  private decode(row: Row): LiveActivityRecord {
    return { ...JSON.parse(row.registration) as LiveActivityRegistration, token: row.token, tokenGeneration: row.token_generation,
      status: row.status, validated: row.validated === 1, content: JSON.parse(row.content) as LiveActivityContentState,
      expiresAt: row.expires_at, failures: row.failures };
  }

  private sameSelection(current: LiveActivityRegistration, next: LiveActivityRegistration): boolean {
    return current.installationId === next.installationId && current.environment === next.environment
      && current.startedAt === next.startedAt && current.trip.id === next.trip.id
      && current.trip.source === next.trip.source && current.trip.nativeId === next.trip.nativeId
      && current.trip.serviceDate === next.trip.serviceDate && current.boardingStationId === next.boardingStationId
      && current.alightingStationId === next.alightingStationId && current.boardingStopSequence === next.boardingStopSequence
      && current.alightingStopSequence === next.alightingStopSequence && current.isRiding === next.isRiding;
  }
}
