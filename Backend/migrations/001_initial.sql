CREATE TABLE IF NOT EXISTS devices (
  installation_id TEXT PRIMARY KEY,
  apns_token TEXT NOT NULL UNIQUE,
  environment TEXT NOT NULL CHECK (environment IN ('sandbox', 'production')),
  platform TEXT NOT NULL CHECK (platform IN ('ios', 'macos')),
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS tracked_trips (
  id TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  native_id TEXT NOT NULL,
  service_date DATE NOT NULL,
  latest_snapshot JSONB,
  next_poll_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  lease_until TIMESTAMPTZ,
  consecutive_failures INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS subscriptions (
  id BIGSERIAL PRIMARY KEY,
  installation_id TEXT NOT NULL REFERENCES devices(installation_id) ON DELETE CASCADE,
  trip_id TEXT NOT NULL REFERENCES tracked_trips(id) ON DELETE CASCADE,
  boarding_station_id TEXT NOT NULL,
  alighting_station_id TEXT NOT NULL,
  watch_from TIMESTAMPTZ NOT NULL,
  preferences JSONB NOT NULL,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (installation_id, trip_id, boarding_station_id, alighting_station_id)
);

CREATE TABLE IF NOT EXISTS notification_events (
  fingerprint TEXT PRIMARY KEY,
  trip_id TEXT NOT NULL REFERENCES tracked_trips(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  stop_id TEXT,
  payload JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS notification_outbox (
  id BIGSERIAL PRIMARY KEY,
  event_fingerprint TEXT NOT NULL REFERENCES notification_events(fingerprint) ON DELETE CASCADE,
  installation_id TEXT NOT NULL REFERENCES devices(installation_id) ON DELETE CASCADE,
  payload JSONB NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'sending', 'delivered', 'failed')),
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  lease_until TIMESTAMPTZ,
  delivered_at TIMESTAMPTZ,
  last_error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (event_fingerprint, installation_id)
);

CREATE INDEX IF NOT EXISTS tracked_trips_due_idx
  ON tracked_trips (next_poll_at, lease_until);

CREATE INDEX IF NOT EXISTS subscriptions_active_trip_idx
  ON subscriptions (trip_id)
  WHERE active = TRUE;

CREATE INDEX IF NOT EXISTS notification_outbox_due_idx
  ON notification_outbox (status, next_attempt_at, lease_until);
