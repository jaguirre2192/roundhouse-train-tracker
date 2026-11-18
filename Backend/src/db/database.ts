import pg from "pg";

const { Pool } = pg;

export type DatabasePool = pg.Pool;
export type DatabaseClient = pg.PoolClient;

export function makeDatabasePool(connectionString: string, ssl: boolean): DatabasePool {
  return new Pool({
    connectionString,
    max: 10,
    ssl: ssl ? { rejectUnauthorized: true } : false,
  });
}

export async function transaction<T>(pool: DatabasePool, work: (client: DatabaseClient) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const result = await work(client);
    await client.query("COMMIT");
    return result;
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  } finally {
    client.release();
  }
}
