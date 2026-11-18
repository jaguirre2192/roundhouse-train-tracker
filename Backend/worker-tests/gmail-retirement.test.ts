import { env } from "cloudflare:test";
import { runInInitializedWatcher as runInDurableObject } from "./initialized-watcher.js";
import { describe, expect, it, vi } from "vitest";
import { GmailRetirement, maximumRevokeAttempts } from "../src/cloudflare/gmail-retirement.js";
import { encryptSecret } from "../src/gmail/gmail-crypto.js";

const key = "worker-test-gmail-token-key-32-characters";
const now = Date.UTC(2026, 9, 25, 2, 0);

async function seed(sql: SqlStorage, accounts: Array<{ id: string; token: string }>): Promise<void> {
  sql.exec("INSERT OR IGNORE INTO gmail_users (id, created_at) VALUES ('user-1', ?)", now);
  sql.exec("INSERT OR IGNORE INTO app_profiles (user_id, email, display_name, created_at, updated_at) VALUES ('user-1', 'rider@example.com', 'Rider', ?, ?)", now, now);
  for (const account of accounts) {
    sql.exec(
      `INSERT INTO gmail_accounts (id, user_id, email_address, encrypted_refresh_token, connected_at, updated_at)
       VALUES (?, 'user-1', ?, ?, ?, ?)`,
      account.id, `${account.id}@gmail.example`, await encryptSecret(account.token, key), now, now,
    );
    sql.exec(
      `INSERT INTO gmail_tickets (id, account_id, message_id, subject, sender, received_at, created_at, updated_at)
       VALUES (?, ?, 'message-1', 'Your ticket', 'tickets@example.com', ?, ?, ?)`,
      `${account.id}-ticket`, account.id, now, now, now,
    );
  }
  sql.exec(
    "INSERT INTO gmail_sessions (token_hash, user_id, expires_at, created_at, last_used_at) VALUES ('hash', 'user-1', ?, ?, ?)",
    now + 1, now, now,
  );
}

const count = (sql: SqlStorage, table: string) =>
  sql.exec<{ count: number }>(`SELECT COUNT(*) AS count FROM ${table}`).one().count;

function revokeEndpoint(responses: Record<string, Response | Error>) {
  return vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
    const token = new URLSearchParams(String(init?.body)).get("token")!;
    const response = responses[token];
    if (response instanceof Error) throw response;
    return response ?? new Response(null, { status: 200 });
  });
}

describe("Gmail data retirement", () => {
  it("revokes each refresh token with Google, then deletes Gmail rows but keeps the account", async () => {
    await runInDurableObject(env.WATCHER.getByName("gmail-retirement-success"), async (_instance, state) => {
      const sql = state.storage.sql;
      await seed(sql, [{ id: "a1", token: "refresh-a1" }, { id: "a2", token: "refresh-a2" }]);
      const fetcher = revokeEndpoint({
        "refresh-a2": new Response(JSON.stringify({ error: "invalid_token" }), { status: 400 }),
      });

      const report = await new GmailRetirement(state.storage, sql, key, fetcher as typeof fetch, () => now).run();

      expect(fetcher).toHaveBeenCalledTimes(2);
      expect(fetcher.mock.calls[0]![0]).toBe("https://oauth2.googleapis.com/revoke");
      expect(fetcher.mock.calls.map(([, init]) => new URLSearchParams(String(init?.body)).get("token")).sort())
        .toEqual(["refresh-a1", "refresh-a2"]);
      expect(report).toEqual({
        deletedAccounts: 2,
        deferredAccounts: 0,
        outcomes: { revoked: 1, already_invalid: 1 },
        remainingAccounts: 0,
      });
      for (const table of ["gmail_accounts", "gmail_tickets", "gmail_sessions", "gmail_oauth_states", "gmail_exchange_codes"]) {
        expect(count(sql, table), table).toBe(0);
      }
      // The shared account and its sign-in profile survive.
      expect(count(sql, "gmail_users")).toBe(1);
      expect(count(sql, "app_profiles")).toBe(1);
    });
  });

  it("keeps an account for a later run when Google is unreachable, then gives up after the cap", async () => {
    await runInDurableObject(env.WATCHER.getByName("gmail-retirement-retry"), async (_instance, state) => {
      const sql = state.storage.sql;
      await seed(sql, [{ id: "b1", token: "refresh-b1" }]);
      const fetcher = revokeEndpoint({ "refresh-b1": new Response("busy", { status: 503 }) });
      const retirement = new GmailRetirement(state.storage, sql, key, fetcher as typeof fetch, () => now);

      for (let attempt = 1; attempt < maximumRevokeAttempts; attempt += 1) {
        expect(await retirement.run()).toMatchObject({ deletedAccounts: 0, deferredAccounts: 1, remainingAccounts: 1 });
      }
      expect(count(sql, "gmail_tickets")).toBe(1);
      expect(await retirement.run()).toMatchObject({ deletedAccounts: 1, outcomes: { abandoned: 1 }, remainingAccounts: 0 });
      expect(count(sql, "gmail_tickets")).toBe(0);
      expect(sql.exec("SELECT 1 FROM runtime_state WHERE key LIKE 'gmail_retirement_attempts:%'").toArray()).toEqual([]);
    });
  });

  it("deletes credentials it cannot decrypt or has no key for without calling Google", async () => {
    await runInDurableObject(env.WATCHER.getByName("gmail-retirement-undecryptable"), async (_instance, state) => {
      const sql = state.storage.sql;
      await seed(sql, [{ id: "c1", token: "refresh-c1" }]);
      const fetcher = revokeEndpoint({});

      expect(await new GmailRetirement(state.storage, sql, "a-different-key-of-32-characters!!", fetcher as typeof fetch).run())
        .toMatchObject({ deletedAccounts: 1, outcomes: { undecryptable: 1 } });
      await seed(sql, [{ id: "c2", token: "refresh-c2" }]);
      expect(await new GmailRetirement(state.storage, sql, null, fetcher as typeof fetch).run())
        .toMatchObject({ deletedAccounts: 1, outcomes: { no_key: 1 } });
      expect(fetcher).not.toHaveBeenCalled();
    });
  });

  it("does nothing and stays quiet once no Gmail data remains", async () => {
    await runInDurableObject(env.WATCHER.getByName("gmail-retirement-empty"), async (_instance, state) => {
      const fetcher = revokeEndpoint({});
      expect(await new GmailRetirement(state.storage, state.storage.sql, key, fetcher as typeof fetch).run())
        .toEqual({ deletedAccounts: 0, deferredAccounts: 0, outcomes: {}, remainingAccounts: 0 });
      expect(fetcher).not.toHaveBeenCalled();
    });
  });
});
