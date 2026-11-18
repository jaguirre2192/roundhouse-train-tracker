import { createSchemaIfMissing } from "./schema-initialization.js";

export function initializeLiveActivitySchema(sql: SqlStorage): void {
  createSchemaIfMissing(sql, `
    CREATE TABLE IF NOT EXISTS live_activity_installations (
      installation_id TEXT PRIMARY KEY,
      credential_hash TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS live_activities (
      activity_id TEXT PRIMARY KEY,
      installation_id TEXT NOT NULL REFERENCES live_activity_installations(installation_id),
      registration TEXT NOT NULL,
      token TEXT NOT NULL,
      token_generation INTEGER NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('active', 'ending', 'ended')),
      validated INTEGER NOT NULL DEFAULT 0,
      content TEXT NOT NULL,
      expires_at INTEGER NOT NULL,
      next_poll_at INTEGER NOT NULL,
      failures INTEGER NOT NULL DEFAULT 0,
      revision INTEGER NOT NULL DEFAULT 0,
      last_timestamp INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );
    CREATE UNIQUE INDEX IF NOT EXISTS live_activity_one_active_installation
      ON live_activities(installation_id) WHERE status = 'active';
    CREATE INDEX IF NOT EXISTS live_activity_due ON live_activities(status, next_poll_at);
    CREATE TABLE IF NOT EXISTS live_activity_outbox (
      activity_id TEXT PRIMARY KEY REFERENCES live_activities(activity_id) ON DELETE CASCADE,
      payload TEXT NOT NULL,
      revision INTEGER NOT NULL,
      token_generation INTEGER NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0,
      next_attempt_at INTEGER NOT NULL,
      lease_until INTEGER NOT NULL DEFAULT 0,
      expires_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS live_activity_stops (
      activity_id TEXT NOT NULL,
      installation_id TEXT NOT NULL,
      stopped_at INTEGER NOT NULL,
      PRIMARY KEY (activity_id, installation_id)
    );
    CREATE TABLE IF NOT EXISTS live_activity_trip_cache (
      trip_key TEXT PRIMARY KEY,
      snapshot TEXT NOT NULL,
      next_fetch_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );
  `);
}
