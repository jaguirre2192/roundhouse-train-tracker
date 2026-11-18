import { env } from "cloudflare:test";
import { expect, it } from "vitest";
import { AuthRepository } from "../src/auth/auth-repository.js";
import { runInInitializedWatcher } from "./initialized-watcher.js";

it("reads live account sessions during a write quota and touches them at most daily", async () => {
  await runInInitializedWatcher(env.WATCHER.getByName("auth-session-reads"), (_, state) => {
    const sql = state.storage.sql;
    const now = Date.now();
    sql.exec("INSERT INTO gmail_users(id,created_at) VALUES ('user',?)", now);
    sql.exec("INSERT INTO app_sessions(token_hash,user_id,expires_at,created_at,last_used_at) VALUES ('hash','user',?,?,?)",
      now + 172_800_000, now, now);
    const repo = new AuthRepository(state.storage);
    const changes = () => sql.exec<{ n: number }>("SELECT total_changes() n").one().n;
    const first = changes();
    expect(repo.userIdForSession("hash", now + 60_000)).toBe("user");
    expect(changes()).toBe(first);
    const readonly = { sql: { exec(query: string, ...bindings: SqlStorageValue[]) {
      if (query.startsWith("UPDATE")) throw new Error("Exceeded allowed rows written in Durable Objects free tier");
      return sql.exec(query, ...bindings);
    } } } as DurableObjectStorage;
    expect(new AuthRepository(readonly).userIdForSession("hash", now + 86_400_001)).toBe("user");
    expect(changes()).toBe(first);
    expect(repo.userIdForSession("hash", now + 86_400_002)).toBe("user");
    expect(repo.userIdForSession("hash", now + 86_400_003)).toBe("user");
    expect(changes()).toBe(first + 1);
    expect(repo.userIdForSession("hash", now + 172_800_000)).toBeNull();
  });
});
