import type { Pool } from "pg";
import type { TripSnapshot } from "../domain/snapshot.js";
import type { SrbijaVozSnapshotStore } from "./srbijavoz-provider.js";

export class PostgresSrbijaVozSnapshotStore implements SrbijaVozSnapshotStore {
  private initialized: Promise<unknown> | undefined;

  constructor(private readonly pool: Pool, private readonly now = () => Date.now()) {}

  private initialize() {
    this.initialized ??= this.pool.query(`CREATE TABLE IF NOT EXISTS srbijavoz_schedules (
      cache_key TEXT PRIMARY KEY, snapshot JSONB NOT NULL, expires_at BIGINT NOT NULL
    )`).catch((error: unknown) => { this.initialized = undefined; throw error; });
    return this.initialized;
  }

  async get(key: string): Promise<TripSnapshot | undefined> {
    await this.initialize();
    const result = await this.pool.query<{ snapshot: TripSnapshot }>(
      "SELECT snapshot FROM srbijavoz_schedules WHERE cache_key = $1 AND expires_at > $2", [key, this.now()],
    );
    return result.rows[0]?.snapshot;
  }

  async put(key: string, snapshot: TripSnapshot): Promise<void> {
    await this.initialize();
    const expiresAt = Date.parse(`${snapshot.serviceDate}T00:00:00Z`) + 3 * 86_400_000;
    if (!Number.isFinite(expiresAt) || expiresAt <= this.now()) return;
    await this.pool.query("DELETE FROM srbijavoz_schedules WHERE expires_at <= $1", [this.now()]);
    await this.pool.query(`INSERT INTO srbijavoz_schedules (cache_key, snapshot, expires_at) VALUES ($1, $2, $3)
      ON CONFLICT(cache_key) DO UPDATE SET snapshot = excluded.snapshot, expires_at = excluded.expires_at`,
    [key, JSON.stringify(snapshot), expiresAt]);
  }
}
