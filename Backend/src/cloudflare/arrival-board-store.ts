import { decryptSecret, encryptSecret, randomToken, sha256 } from "../gmail/gmail-crypto.js";
import type { ArrivalBoardRecord, ArrivalReport } from "../domain/arrival-board.js";
import { afterArrival } from "../domain/arrival-board.js";
import { createSchemaIfMissing } from "./schema-initialization.js";

interface Row extends Record<string, SqlStorageValue> {
  sealed: string; expires: number; settled: string | null; kind: ArrivalReport["kind"] | null;
}

/** The random capability stays with the traveler. Even the text encrypted in this table
 * needs the capability to be read. Ordinary recipient refreshes only read this row. */
export class ArrivalBoardStore {
  private initialized = false;
  constructor(private readonly sql: SqlStorage) {}

  async create(record: ArrivalBoardRecord, expires: number) {
    this.prepare();
    const token = randomToken();
    const hash = await sha256(token);
    const sealed = await encryptSecret(JSON.stringify(record), "arrival-board:v1:" + token);
    this.sql.exec("INSERT INTO arrival_boards (id, sealed, expires) VALUES (?, ?, ?)", hash, sealed, expires);
    return token;
  }

  async load(token: string, now: number) {
    if (!/^[A-Za-z0-9_-]{43}$/u.test(token)) return null;
    this.prepare();
    const hash = await sha256(token);
    const row = this.row(hash, now);
    if (!row) return null;
    const record = JSON.parse(await decryptSecret(row.sealed, "arrival-board:v1:" + token)) as ArrivalBoardRecord;
    return { hash, record, row };
  }

  row(hash: string, now: number): Row | undefined {
    return this.sql.exec<Row>("SELECT sealed, expires, settled, kind FROM arrival_boards WHERE id = ? AND expires > ?",
      hash, now).toArray()[0];
  }

  settle(hash: string, report: ArrivalReport): void {
    this.sql.exec("UPDATE arrival_boards SET settled = ?, kind = ?, expires = MIN(expires, ?) WHERE id = ? AND settled IS NULL",
      report.observedAt, report.kind, Date.parse(report.observedAt) + afterArrival, hash);
  }

  prune(now: number): void {
    if (!this.initialized && !this.sql.exec("SELECT 1 FROM sqlite_master WHERE name = 'arrival_boards'").toArray().length) return;
    if (!this.sql.exec("SELECT 1 FROM arrival_boards WHERE expires <= ? LIMIT 1", now).toArray().length) return;
    this.sql.exec("DELETE FROM arrival_boards WHERE id IN (SELECT id FROM arrival_boards WHERE expires <= ? ORDER BY expires LIMIT 256)", now);
  }

  private prepare(): void {
    if (this.initialized) return;
    createSchemaIfMissing(this.sql, `CREATE TABLE IF NOT EXISTS arrival_boards (
      id TEXT PRIMARY KEY, sealed TEXT NOT NULL, expires INTEGER NOT NULL, settled TEXT, kind TEXT
    ); CREATE INDEX IF NOT EXISTS arrival_boards_expires ON arrival_boards (expires)`);
    this.initialized = true;
  }
}
