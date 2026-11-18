import { readdir, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { join, resolve } from "node:path";
import { loadConfig } from "./config.js";
import { makeDatabasePool } from "./db/database.js";

export async function migrate(migrationsDirectory?: string): Promise<void> {
  const config = await loadConfig();
  const pool = makeDatabasePool(config.databaseUrl, config.databaseSSL);
  const directory = migrationsDirectory ?? resolve(process.cwd(), "migrations");

  try {
    await pool.query(
      `CREATE TABLE IF NOT EXISTS schema_migrations (
         name TEXT PRIMARY KEY,
         applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
       )`,
    );
    const files = (await readdir(directory)).filter((file) => file.endsWith(".sql")).sort();
    for (const file of files) {
      const exists = await pool.query("SELECT 1 FROM schema_migrations WHERE name = $1", [file]);
      if (exists.rowCount !== 0) continue;
      const sql = await readFile(join(directory, file), "utf8");
      const client = await pool.connect();
      try {
        await client.query("BEGIN");
        await client.query(sql);
        await client.query("INSERT INTO schema_migrations (name) VALUES ($1)", [file]);
        await client.query("COMMIT");
      } catch (error) {
        await client.query("ROLLBACK");
        throw error;
      } finally {
        client.release();
      }
    }
  } finally {
    await pool.end();
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await migrate();
}
