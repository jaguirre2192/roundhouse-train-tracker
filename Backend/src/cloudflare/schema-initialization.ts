/** Existing schemas must be able to start when storage writes are unavailable. */
export function createSchemaIfMissing(sql: SqlStorage, definition: string): boolean {
  const required = [...definition.matchAll(
    /\bCREATE\s+(?:UNIQUE\s+)?(TABLE|INDEX)\s+IF\s+NOT\s+EXISTS\s+([a-z_][a-z0-9_]*)/giu,
  )].map((match) => `${match[1]!.toLowerCase()}:${match[2]!.toLowerCase()}`);
  if (required.length === 0) throw new Error("Schema definition has no guarded tables or indexes");
  const existing = new Set(sql.exec<{ type: string; name: string }>(
    "SELECT type, name FROM sqlite_master WHERE type IN ('table', 'index')",
  ).toArray().map((row) => `${row.type}:${row.name.toLowerCase()}`));
  if (required.every((name) => existing.has(name))) return false;
  sql.exec(definition);
  return true;
}

export function ensureForeignKeys(sql: SqlStorage): void {
  // The production write-quota gate also rejects read-form PRAGMA statements.
  // Use SQLite's read-only table function; keep enforcement on for all writes.
  if (sql.exec<{ foreign_keys: number }>("SELECT foreign_keys FROM pragma_foreign_keys").one().foreign_keys !== 1) {
    sql.exec("PRAGMA foreign_keys = ON");
  }
}
