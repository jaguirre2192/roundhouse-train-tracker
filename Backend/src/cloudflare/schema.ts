import { initializeLiveActivitySchema } from "./live-activity-schema.js";
import { createSchemaIfMissing, ensureForeignKeys } from "./schema-initialization.js";

export function initializeSchema(sql: SqlStorage): void {
  ensureForeignKeys(sql);
  createSchemaIfMissing(sql, `
    CREATE TABLE IF NOT EXISTS devices (
      installation_id TEXT PRIMARY KEY,
      apns_token TEXT NOT NULL UNIQUE,
      credential_hash TEXT,
      environment TEXT NOT NULL CHECK (environment IN ('sandbox', 'production')),
      platform TEXT NOT NULL CHECK (platform IN ('ios', 'macos')),
      active INTEGER NOT NULL DEFAULT 1,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS tracked_trips (
      id TEXT PRIMARY KEY,
      client_trip_id TEXT NOT NULL,
      source TEXT NOT NULL,
      native_id TEXT NOT NULL,
      service_date TEXT NOT NULL,
      latest_snapshot TEXT,
      next_poll_at INTEGER NOT NULL,
      consecutive_failures INTEGER NOT NULL DEFAULT 0,
      last_error TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      UNIQUE (client_trip_id, service_date)
    );

    CREATE TABLE IF NOT EXISTS platform_observations (
      fingerprint TEXT PRIMARY KEY,
      market TEXT NOT NULL CHECK (market IN ('western-europe', 'north-america')),
      country_code TEXT NOT NULL,
      policy_version INTEGER NOT NULL,
      source_name TEXT NOT NULL,
      source_license TEXT NOT NULL,
      source_attribution TEXT NOT NULL,
      source_evidence_url TEXT NOT NULL,
      trip_id TEXT NOT NULL,
      trip_source TEXT NOT NULL,
      native_trip_id TEXT NOT NULL,
      service_date TEXT NOT NULL,
      operator_name TEXT NOT NULL,
      product TEXT NOT NULL,
      headsign TEXT NOT NULL,
      route_signature TEXT NOT NULL,
      station_id TEXT NOT NULL,
      station_name TEXT NOT NULL,
      stop_sequence INTEGER NOT NULL,
      call_type TEXT NOT NULL CHECK (call_type IN ('arrival', 'departure', 'arrival-departure', 'unknown')),
      scheduled_arrival INTEGER,
      scheduled_departure INTEGER,
      expected_arrival INTEGER,
      expected_departure INTEGER,
      planned_platform TEXT,
      expected_platform TEXT,
      effective_platform TEXT NOT NULL,
      platform_observed_at INTEGER NOT NULL,
      snapshot_fetched_at INTEGER NOT NULL,
      collection_trigger TEXT NOT NULL CHECK (collection_trigger IN ('snapshot', 'watcher')),
      first_observed_at INTEGER NOT NULL,
      last_observed_at INTEGER NOT NULL,
      sample_count INTEGER NOT NULL DEFAULT 1,
      passed INTEGER NOT NULL CHECK (passed IN (0, 1)),
      cancelled INTEGER NOT NULL CHECK (cancelled IN (0, 1)),
      payload TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS platform_shadow_forecasts (
      id TEXT PRIMARY KEY,
      event_id TEXT NOT NULL,
      source_name TEXT NOT NULL,
      station_id TEXT NOT NULL,
      station_name TEXT NOT NULL,
      service_date TEXT NOT NULL,
      stop_sequence INTEGER NOT NULL,
      event_type TEXT NOT NULL CHECK (event_type IN ('arrival', 'departure')),
      scheduled_time INTEGER NOT NULL,
      horizon TEXT NOT NULL,
      model_version TEXT NOT NULL,
      timetable_period TEXT NOT NULL,
      cohort TEXT NOT NULL,
      evidence_count INTEGER NOT NULL,
      likely_platform TEXT NOT NULL,
      top_probability REAL NOT NULL,
      candidates TEXT NOT NULL,
      generated_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL,
      zone_id TEXT,
      zone_platforms TEXT,
      actual_platform TEXT,
      scored_at INTEGER,
      exact_correct INTEGER CHECK (exact_correct IS NULL OR exact_correct IN (0, 1)),
      zone_correct INTEGER CHECK (zone_correct IS NULL OR zone_correct IN (0, 1)),
      harmful_displacement INTEGER CHECK (harmful_displacement IS NULL OR harmful_displacement IN (0, 1))
    );

    CREATE TABLE IF NOT EXISTS platform_sample_trips (
      id TEXT PRIMARY KEY,
      source TEXT NOT NULL CHECK (source = 'transitous'),
      native_id TEXT NOT NULL,
      service_date TEXT NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('active', 'completed', 'failed')),
      next_poll_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL,
      consecutive_failures INTEGER NOT NULL DEFAULT 0,
      last_error TEXT,
      completed_at INTEGER,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS subscriptions (
      installation_id TEXT NOT NULL REFERENCES devices(installation_id) ON DELETE CASCADE,
      trip_id TEXT NOT NULL REFERENCES tracked_trips(id) ON DELETE CASCADE,
      boarding_station_id TEXT NOT NULL,
      alighting_station_id TEXT NOT NULL,
      watch_from INTEGER NOT NULL,
      preferences TEXT NOT NULL,
      active INTEGER NOT NULL DEFAULT 1,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (installation_id, trip_id, boarding_station_id, alighting_station_id)
    );

    CREATE TABLE IF NOT EXISTS notification_events (
      fingerprint TEXT PRIMARY KEY,
      trip_id TEXT NOT NULL REFERENCES tracked_trips(id) ON DELETE CASCADE,
      kind TEXT NOT NULL,
      stop_id TEXT,
      payload TEXT NOT NULL,
      created_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS notification_outbox (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      event_fingerprint TEXT NOT NULL REFERENCES notification_events(fingerprint) ON DELETE CASCADE,
      installation_id TEXT NOT NULL REFERENCES devices(installation_id) ON DELETE CASCADE,
      payload TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'sending', 'delivered', 'failed')),
      attempts INTEGER NOT NULL DEFAULT 0,
      next_attempt_at INTEGER NOT NULL,
      delivered_at INTEGER,
      last_error TEXT,
      created_at INTEGER NOT NULL,
      UNIQUE (event_fingerprint, installation_id)
    );

    CREATE TABLE IF NOT EXISTS runtime_state (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL,
      updated_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS mutation_rate_windows (
      key TEXT PRIMARY KEY,
      window_started_at INTEGER NOT NULL,
      request_count INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS darwin_cache_files (
      name TEXT NOT NULL,
      part INTEGER NOT NULL,
      payload BLOB NOT NULL,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (name, part)
    );

    CREATE TABLE IF NOT EXISTS darwin_cache_state (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL,
      updated_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS gmail_users (
      id TEXT PRIMARY KEY,
      created_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS app_profiles (
      user_id TEXT PRIMARY KEY REFERENCES gmail_users(id) ON DELETE CASCADE,
      email TEXT,
      display_name TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS app_identities (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES gmail_users(id) ON DELETE CASCADE,
      provider TEXT NOT NULL CHECK (provider IN ('apple', 'google')),
      subject TEXT NOT NULL,
      email TEXT,
      display_name TEXT,
      client_id TEXT NOT NULL,
      encrypted_refresh_token TEXT,
      created_at INTEGER NOT NULL,
      last_login_at INTEGER NOT NULL,
      UNIQUE (provider, subject)
    );

    CREATE TABLE IF NOT EXISTS app_sessions (
      token_hash TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES gmail_users(id) ON DELETE CASCADE,
      expires_at INTEGER NOT NULL,
      created_at INTEGER NOT NULL,
      last_used_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS auth_google_states (
      state_hash TEXT PRIMARY KEY,
      verifier TEXT NOT NULL,
      transaction_id TEXT NOT NULL,
      app_challenge TEXT NOT NULL,
      expected_user_id TEXT REFERENCES gmail_users(id) ON DELETE CASCADE,
      expires_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS auth_exchange_codes (
      code_hash TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES gmail_users(id) ON DELETE CASCADE,
      transaction_id TEXT NOT NULL,
      app_challenge TEXT NOT NULL,
      expires_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS gmail_accounts (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES gmail_users(id) ON DELETE CASCADE,
      email_address TEXT NOT NULL UNIQUE,
      encrypted_refresh_token TEXT NOT NULL,
      history_id TEXT,
      watch_expires_at INTEGER,
      connected_at INTEGER NOT NULL,
      last_scan_at INTEGER,
      last_error TEXT,
      updated_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS gmail_oauth_states (
      state_hash TEXT PRIMARY KEY,
      verifier TEXT NOT NULL,
      link_user_id TEXT REFERENCES gmail_users(id) ON DELETE CASCADE,
      transaction_id TEXT,
      app_challenge TEXT,
      expires_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS gmail_exchange_codes (
      code_hash TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES gmail_users(id) ON DELETE CASCADE,
      transaction_id TEXT,
      app_challenge TEXT,
      expires_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS gmail_sessions (
      token_hash TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES gmail_users(id) ON DELETE CASCADE,
      expires_at INTEGER NOT NULL,
      created_at INTEGER NOT NULL,
      last_used_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS gmail_manual_scan_state (
      user_id TEXT PRIMARY KEY REFERENCES gmail_users(id) ON DELETE CASCADE,
      next_allowed_at INTEGER NOT NULL,
      lease_until INTEGER,
      last_started_at INTEGER NOT NULL,
      last_finished_at INTEGER
    );

    CREATE TABLE IF NOT EXISTS forwarding_aliases (
      user_id TEXT PRIMARY KEY REFERENCES gmail_users(id) ON DELETE CASCADE,
      alias_nonce TEXT NOT NULL,
      token_hash TEXT NOT NULL UNIQUE,
      created_at INTEGER NOT NULL,
      rotated_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS forwarded_tickets (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES gmail_users(id) ON DELETE CASCADE,
      message_key TEXT NOT NULL,
      subject TEXT NOT NULL,
      sender TEXT NOT NULL,
      received_at INTEGER NOT NULL,
      operator_name TEXT,
      train_number TEXT,
      origin_name TEXT,
      destination_name TEXT,
      departure_time TEXT,
      arrival_time TEXT,
      booking_reference TEXT,
      passenger_name TEXT,
      coach TEXT,
      seat TEXT,
      artifact_mime_type TEXT,
      artifact_filename TEXT,
      artifact_data TEXT,
      created_at INTEGER NOT NULL,
      UNIQUE (user_id, message_key)
    );

    CREATE TABLE IF NOT EXISTS gmail_tickets (
      id TEXT PRIMARY KEY,
      account_id TEXT NOT NULL REFERENCES gmail_accounts(id) ON DELETE CASCADE,
      message_id TEXT NOT NULL,
      subject TEXT NOT NULL,
      sender TEXT NOT NULL,
      received_at INTEGER NOT NULL,
      operator_name TEXT,
      train_number TEXT,
      origin_name TEXT,
      destination_name TEXT,
      departure_time TEXT,
      arrival_time TEXT,
      booking_reference TEXT,
      passenger_name TEXT,
      coach TEXT,
      seat TEXT,
      artifact_json TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      UNIQUE (account_id, message_id)
    );

    CREATE INDEX IF NOT EXISTS tracked_trips_due_idx
      ON tracked_trips (next_poll_at);
    CREATE INDEX IF NOT EXISTS platform_observations_station_service_idx
      ON platform_observations (market, country_code, station_id, service_date);
    CREATE INDEX IF NOT EXISTS platform_observations_station_departure_idx
      ON platform_observations (station_id, scheduled_departure, effective_platform);
    CREATE INDEX IF NOT EXISTS platform_observations_source_service_idx
      ON platform_observations (source_name, service_date);
    CREATE INDEX IF NOT EXISTS platform_observations_last_seen_idx
      ON platform_observations (last_observed_at);
    CREATE INDEX IF NOT EXISTS platform_shadow_forecasts_event_idx
      ON platform_shadow_forecasts (event_id, scored_at);
    CREATE INDEX IF NOT EXISTS platform_shadow_forecasts_cohort_idx
      ON platform_shadow_forecasts (station_id, source_name, event_type, horizon, generated_at);
    CREATE INDEX IF NOT EXISTS subscriptions_active_trip_idx
      ON subscriptions (trip_id, active, watch_from);
    CREATE INDEX IF NOT EXISTS notification_outbox_due_idx
      ON notification_outbox (status, next_attempt_at);
    CREATE INDEX IF NOT EXISTS gmail_accounts_user_idx
      ON gmail_accounts (user_id);
    CREATE UNIQUE INDEX IF NOT EXISTS app_profiles_email_unique_idx
      ON app_profiles (lower(email)) WHERE email IS NOT NULL;
    CREATE INDEX IF NOT EXISTS app_identities_user_idx
      ON app_identities (user_id);
    CREATE INDEX IF NOT EXISTS app_sessions_user_expiry_idx
      ON app_sessions (user_id, expires_at);
    CREATE INDEX IF NOT EXISTS auth_google_states_expiry_idx
      ON auth_google_states (expires_at);
    CREATE INDEX IF NOT EXISTS auth_exchange_codes_expiry_idx
      ON auth_exchange_codes (expires_at);
    CREATE INDEX IF NOT EXISTS gmail_accounts_scan_idx
      ON gmail_accounts (last_scan_at);
    CREATE INDEX IF NOT EXISTS gmail_tickets_account_received_idx
      ON gmail_tickets (account_id, received_at DESC);
    CREATE INDEX IF NOT EXISTS forwarded_tickets_user_received_idx
      ON forwarded_tickets (user_id, received_at DESC);
  `);
  const deviceColumns = sql.exec<{ name: string }>("SELECT name FROM pragma_table_info('devices')").toArray();
  if (!deviceColumns.some((column) => column.name === "credential_hash")) {
    sql.exec("ALTER TABLE devices ADD COLUMN credential_hash TEXT");
  }
  const gmailColumns = sql.exec<{ name: string }>("SELECT name FROM pragma_table_info('gmail_accounts')").toArray();
  if (!gmailColumns.some((column) => column.name === "watch_expires_at")) {
    sql.exec("ALTER TABLE gmail_accounts ADD COLUMN watch_expires_at INTEGER");
  }
  const gmailOAuthColumns = sql.exec<{ name: string }>("SELECT name FROM pragma_table_info('gmail_oauth_states')").toArray();
  if (!gmailOAuthColumns.some((column) => column.name === "transaction_id")) {
    sql.exec("ALTER TABLE gmail_oauth_states ADD COLUMN transaction_id TEXT");
  }
  if (!gmailOAuthColumns.some((column) => column.name === "app_challenge")) {
    sql.exec("ALTER TABLE gmail_oauth_states ADD COLUMN app_challenge TEXT");
  }
  const gmailExchangeColumns = sql.exec<{ name: string }>("SELECT name FROM pragma_table_info('gmail_exchange_codes')").toArray();
  if (!gmailExchangeColumns.some((column) => column.name === "transaction_id")) {
    sql.exec("ALTER TABLE gmail_exchange_codes ADD COLUMN transaction_id TEXT");
  }
  if (!gmailExchangeColumns.some((column) => column.name === "app_challenge")) {
    sql.exec("ALTER TABLE gmail_exchange_codes ADD COLUMN app_challenge TEXT");
  }
  initializeLiveActivitySchema(sql);
}
