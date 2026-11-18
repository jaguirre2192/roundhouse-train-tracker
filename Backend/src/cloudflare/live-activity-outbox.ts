import { APNsError } from "../apns/transport.js";
import { hasActionableBoardingPlatform, type LiveActivityPush, type LiveActivitySender } from "../domain/live-activity.js";
import type { LiveActivityStore } from "./live-activity-store.js";

interface OutboxRow extends Record<string, SqlStorageValue> {
  activity_id: string; payload: string; revision: number; token_generation: number; attempts: number;
}

export class LiveActivityOutbox {
  constructor(private readonly storage: DurableObjectStorage,
    private readonly store: LiveActivityStore, private readonly sender: LiveActivitySender) {}

  async deliver(now = Date.now()): Promise<void> {
    const sql = this.storage.sql;
    const rows = this.storage.transactionSync(() => {
      const due = sql.exec<OutboxRow>(`SELECT * FROM live_activity_outbox
        WHERE next_attempt_at <= ? AND lease_until <= ? AND expires_at > ? ORDER BY next_attempt_at LIMIT 20`, now, now, now).toArray();
      for (const row of due) sql.exec("UPDATE live_activity_outbox SET lease_until = ? WHERE activity_id = ? AND revision = ?",
        now + 30_000, row.activity_id, row.revision);
      return due;
    });
    await Promise.all(rows.map(async (row) => {
      const message = JSON.parse(row.payload) as LiveActivityPush;
      const current = this.store.get(row.activity_id);
      if (current === null || current.status === "ended" || current.tokenGeneration !== row.token_generation
        || (current.status === "ending" && message.event !== "end")) return;
      if (message.alert !== undefined && !hasActionableBoardingPlatform(message.content, current, now / 1_000)) delete message.alert;
      try {
        await this.sender.send(message);
        this.storage.transactionSync(() => {
          const matching = sql.exec("SELECT 1 FROM live_activity_outbox WHERE activity_id = ? AND revision = ? AND token_generation = ?",
            row.activity_id, row.revision, row.token_generation).toArray().length > 0;
          if (!matching) return;
          if (message.event === "end") this.store.retire(row.activity_id, row.token_generation, Date.now());
          else sql.exec("DELETE FROM live_activity_outbox WHERE activity_id = ? AND revision = ? AND token_generation = ?",
            row.activity_id, row.revision, row.token_generation);
        });
        console.info("live_activity_delivery", { event: message.event, outcome: "delivered" });
      } catch (error) {
        if (error instanceof APNsError && error.invalidatesDevice) {
          this.store.retire(row.activity_id, row.token_generation, Date.now());
        } else {
          const retry = Math.min(300_000, 15_000 * 2 ** Math.min(row.attempts, 5));
          sql.exec(`UPDATE live_activity_outbox SET attempts = attempts + 1, lease_until = 0, next_attempt_at = ?
            WHERE activity_id = ? AND revision = ? AND token_generation = ?`,
          now + retry, row.activity_id, row.revision, row.token_generation);
        }
        console.info("live_activity_delivery", { event: message.event,
          outcome: error instanceof APNsError && error.invalidatesDevice ? "retired" : "retry" });
      }
    }));
  }
}
