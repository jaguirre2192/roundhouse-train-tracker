ALTER TABLE tracked_trips
  ADD COLUMN IF NOT EXISTS client_trip_id TEXT;

UPDATE tracked_trips
SET client_trip_id = id
WHERE client_trip_id IS NULL;

ALTER TABLE tracked_trips
  ALTER COLUMN client_trip_id SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS tracked_trips_client_service_idx
  ON tracked_trips (client_trip_id, service_date);
