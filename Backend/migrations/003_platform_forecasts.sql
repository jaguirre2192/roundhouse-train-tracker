CREATE TABLE IF NOT EXISTS platform_shadow_forecasts (
  id TEXT PRIMARY KEY,
  event_id TEXT NOT NULL,
  source_name TEXT NOT NULL,
  station_id TEXT NOT NULL,
  station_name TEXT NOT NULL,
  service_date DATE NOT NULL,
  stop_sequence INTEGER NOT NULL,
  event_type TEXT NOT NULL CHECK (event_type IN ('arrival', 'departure')),
  scheduled_time TIMESTAMPTZ NOT NULL,
  horizon TEXT NOT NULL,
  model_version TEXT NOT NULL,
  timetable_period TEXT NOT NULL,
  cohort TEXT NOT NULL,
  evidence_count INTEGER NOT NULL,
  likely_platform TEXT NOT NULL,
  top_probability DOUBLE PRECISION NOT NULL,
  candidates JSONB NOT NULL,
  generated_at TIMESTAMPTZ NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  zone_id TEXT,
  zone_platforms JSONB,
  actual_platform TEXT,
  scored_at TIMESTAMPTZ,
  exact_correct BOOLEAN,
  zone_correct BOOLEAN,
  harmful_displacement BOOLEAN
);

CREATE INDEX IF NOT EXISTS platform_shadow_forecasts_event_idx
  ON platform_shadow_forecasts (event_id, scored_at);
CREATE INDEX IF NOT EXISTS platform_shadow_forecasts_cohort_idx
  ON platform_shadow_forecasts (station_id, source_name, event_type, horizon, generated_at);
