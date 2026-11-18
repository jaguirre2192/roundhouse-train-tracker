import type { TripSnapshot } from "../domain/snapshot.js";
import type { SrbijaVozSnapshotStore } from "../providers/srbijavoz-provider.js";
import { createSchemaIfMissing } from "./schema-initialization.js";

interface Row extends Record<string, SqlStorageValue> { snapshot: string }

/** Public dated timetables survive Worker restarts without becoming fresh data. */
export class SQLiteSrbijaVozSnapshotStore implements SrbijaVozSnapshotStore {
  private initialized = false;

  constructor(private readonly sql: SqlStorage, private readonly now = () => Date.now()) {}

  async get(key: string): Promise<TripSnapshot | undefined> {
    this.ensureSchema();
    const row = this.sql.exec<Row>(
      "SELECT snapshot FROM srbijavoz_schedules WHERE cache_key = ? AND expires_at > ?", key, this.now(),
    ).toArray()[0];
    return row === undefined ? undefined : JSON.parse(row.snapshot) as TripSnapshot;
  }

  async put(key: string, snapshot: TripSnapshot): Promise<void> {
    // The provider applies the stricter journey/end-of-next-day fallback bound.
    const expiresAt = Date.parse(`${snapshot.serviceDate}T00:00:00Z`) + 3 * 86_400_000;
    if (!Number.isFinite(expiresAt) || expiresAt <= this.now()) return;
    this.ensureSchema();
    this.sql.exec("DELETE FROM srbijavoz_schedules WHERE expires_at <= ?", this.now());
    this.sql.exec(`INSERT INTO srbijavoz_schedules (cache_key, snapshot, expires_at) VALUES (?, ?, ?)
      ON CONFLICT(cache_key) DO UPDATE SET snapshot = excluded.snapshot, expires_at = excluded.expires_at`,
    key, JSON.stringify(snapshot), expiresAt);
  }

  private ensureSchema(): void {
    if (this.initialized) return;
    createSchemaIfMissing(this.sql, `CREATE TABLE IF NOT EXISTS srbijavoz_schedules (
      cache_key TEXT PRIMARY KEY, snapshot TEXT NOT NULL, expires_at INTEGER NOT NULL
    )`);
    this.initialized = true;
  }
}
