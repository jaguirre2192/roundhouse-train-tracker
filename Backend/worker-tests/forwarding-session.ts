import { env } from "cloudflare:test";
import { sha256 } from "../src/gmail/gmail-crypto.js";
import { runInInitializedWatcher as runInDurableObject } from "./initialized-watcher.js";

export async function createSession(userId: string): Promise<string> {
  const stub = env.WATCHER.getByName("global");
  await runInDurableObject(stub, (_instance, state) => {
    const now = Date.now();
    state.storage.sql.exec("INSERT OR IGNORE INTO gmail_users (id, created_at) VALUES (?, ?)", userId, now);
    state.storage.sql.exec(
      `INSERT INTO app_profiles (user_id, email, display_name, created_at, updated_at)
       VALUES (?, NULL, NULL, ?, ?)
       ON CONFLICT (user_id) DO NOTHING`,
      userId,
      now,
      now,
    );
  });
  const token = `test-session-${userId}-${crypto.randomUUID()}`;
  await stub.createAuthSession(userId, await sha256(token), Date.now() + 60 * 60_000);
  return token;
}

export function authorized(token: string): HeadersInit {
  return { authorization: `Bearer ${token}` };
}
