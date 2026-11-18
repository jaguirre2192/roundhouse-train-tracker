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
  service_date DATE NOT NULL,
  operator_name TEXT NOT NULL,
  product TEXT NOT NULL,
  headsign TEXT NOT NULL,
  route_signature TEXT NOT NULL,
  station_id TEXT NOT NULL,
  station_name TEXT NOT NULL,
  stop_sequence INTEGER NOT NULL,
  call_type TEXT NOT NULL CHECK (call_type IN ('arrival', 'departure', 'arrival-departure', 'unknown')),
  scheduled_arrival TIMESTAMPTZ,
  scheduled_departure TIMESTAMPTZ,
  expected_arrival TIMESTAMPTZ,
  expected_departure TIMESTAMPTZ,
  planned_platform TEXT,
  expected_platform TEXT,
  effective_platform TEXT NOT NULL,
  platform_observed_at TIMESTAMPTZ NOT NULL,
  snapshot_fetched_at TIMESTAMPTZ NOT NULL,
  collection_trigger TEXT NOT NULL CHECK (collection_trigger IN ('snapshot', 'watcher')),
  first_observed_at TIMESTAMPTZ NOT NULL,
  last_observed_at TIMESTAMPTZ NOT NULL,
  sample_count INTEGER NOT NULL DEFAULT 1,
  passed BOOLEAN NOT NULL,
  cancelled BOOLEAN NOT NULL,
  payload JSONB NOT NULL
);

CREATE INDEX IF NOT EXISTS platform_observations_station_service_idx
  ON platform_observations (market, country_code, station_id, service_date);
CREATE INDEX IF NOT EXISTS platform_observations_station_departure_idx
  ON platform_observations (station_id, scheduled_departure, effective_platform);
CREATE INDEX IF NOT EXISTS platform_observations_source_service_idx
  ON platform_observations (source_name, service_date);
CREATE INDEX IF NOT EXISTS platform_observations_last_seen_idx
  ON platform_observations (last_observed_at);
