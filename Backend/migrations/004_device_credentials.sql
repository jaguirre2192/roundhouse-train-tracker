-- Device possession credentials for the self-hosted API, matching the Worker.
-- Existing rows keep a NULL hash: they can be claimed only by re-registering
-- the same APNs token, after which every mutation requires the credential.
ALTER TABLE devices
  ADD COLUMN IF NOT EXISTS credential_hash TEXT;
