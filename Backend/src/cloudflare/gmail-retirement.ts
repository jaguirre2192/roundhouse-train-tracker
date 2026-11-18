import { decryptSecret } from "../gmail/gmail-crypto.js";

const googleRevokeURL = "https://oauth2.googleapis.com/revoke";
const attemptKeyPrefix = "gmail_retirement_attempts:";
/// Transient revoke failures are retried on later cron runs (every 15 minutes).
/// After this many, the stored credential is deleted anyway so no data lingers.
export const maximumRevokeAttempts = 8;
/// Accounts handled per run, keeping each cron invocation short.
export const retirementBatchSize = 25;

// Gmail-only tables. `gmail_users` is the shared account table for Apple/Google
// sign-in and forwarding, so it is deliberately kept.
const gmailStateTables = [
  "gmail_oauth_states",
  "gmail_exchange_codes",
  "gmail_sessions",
  "gmail_manual_scan_state",
] as const;

export type GmailRevokeOutcome = "revoked" | "already_invalid" | "undecryptable" | "no_key" | "abandoned";

export interface GmailRetirementReport {
  deletedAccounts: number;
  deferredAccounts: number;
  outcomes: Partial<Record<GmailRevokeOutcome, number>>;
  remainingAccounts: number;
}

interface AccountRow extends Record<string, SqlStorageValue> {
  id: string;
  encrypted_refresh_token: string;
}

/// Revokes every stored Gmail refresh token with Google, then deletes the Gmail
/// accounts, imported Gmail tickets, and Gmail-only OAuth/session/scan state.
export class GmailRetirement {
  constructor(
    private readonly storage: DurableObjectStorage,
    private readonly sql: SqlStorage,
    private readonly encryptionKey: string | null,
    private readonly fetcher: typeof fetch = fetch,
    private readonly now: () => number = Date.now,
  ) {}

  remainingAccounts(): number {
    return this.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM gmail_accounts").one().count;
  }

  async run(batchSize = retirementBatchSize): Promise<GmailRetirementReport> {
    const accounts = this.sql.exec<AccountRow>(
      "SELECT id, encrypted_refresh_token FROM gmail_accounts ORDER BY id LIMIT ?",
      batchSize,
    ).toArray();
    const outcomes: GmailRetirementReport["outcomes"] = {};
    let deletedAccounts = 0;
    let deferredAccounts = 0;
    for (const account of accounts) {
      const outcome = await this.revoke(account);
      if (outcome === null) {
        deferredAccounts += 1;
        continue;
      }
      outcomes[outcome] = (outcomes[outcome] ?? 0) + 1;
      this.deleteAccount(account.id);
      deletedAccounts += 1;
    }
    const remainingAccounts = this.remainingAccounts();
    if (remainingAccounts === 0) this.deleteRemainingGmailState();
    const report = { deletedAccounts, deferredAccounts, outcomes, remainingAccounts };
    if (accounts.length > 0) console.info("gmail_retirement", report);
    return report;
  }

  /// Returns the terminal outcome, or null when the revoke should be retried later.
  private async revoke(account: AccountRow): Promise<GmailRevokeOutcome | null> {
    if (this.encryptionKey === null) return "no_key";
    let refreshToken: string;
    try {
      refreshToken = await decryptSecret(account.encrypted_refresh_token, this.encryptionKey);
    } catch {
      return "undecryptable";
    }
    try {
      const response = await this.fetcher(googleRevokeURL, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ token: refreshToken }).toString(),
        signal: AbortSignal.timeout(5_000),
      });
      if (response.ok) return "revoked";
      if (response.status === 400) {
        const body = await response.json().catch(() => null) as { error?: unknown } | null;
        // Google answers invalid_token for a credential that was already revoked or expired.
        if (body?.error === "invalid_token") return "already_invalid";
      }
    } catch {
      // Network failure or timeout: retry on a later run.
    }
    return this.recordFailedAttempt(account.id) >= maximumRevokeAttempts ? "abandoned" : null;
  }

  private recordFailedAttempt(accountId: string): number {
    const key = attemptKeyPrefix + accountId;
    const previous = Number(this.sql.exec<{ value: string }>(
      "SELECT value FROM runtime_state WHERE key = ?",
      key,
    ).toArray()[0]?.value ?? 0);
    const attempts = previous + 1;
    this.sql.exec(
      `INSERT INTO runtime_state (key, value, updated_at) VALUES (?, ?, ?)
       ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
      key,
      String(attempts),
      this.now(),
    );
    return attempts;
  }

  private deleteAccount(accountId: string): void {
    this.storage.transactionSync(() => {
      this.sql.exec("DELETE FROM gmail_tickets WHERE account_id = ?", accountId);
      this.sql.exec("DELETE FROM gmail_accounts WHERE id = ?", accountId);
      this.sql.exec("DELETE FROM runtime_state WHERE key = ?", attemptKeyPrefix + accountId);
    });
  }

  private deleteRemainingGmailState(): void {
    this.storage.transactionSync(() => {
      this.sql.exec("DELETE FROM gmail_tickets");
      for (const table of gmailStateTables) this.sql.exec(`DELETE FROM ${table}`);
      this.sql.exec("DELETE FROM runtime_state WHERE key LIKE ?", `${attemptKeyPrefix}%`);
    });
  }
}
