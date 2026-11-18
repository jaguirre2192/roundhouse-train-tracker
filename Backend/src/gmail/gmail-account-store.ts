import type {
  GmailAccountSecret,
  GmailConnectResult,
  GmailConnectionSummary,
} from "./gmail-models.js";

interface AccountRow extends Record<string, SqlStorageValue> {
  id: string;
  user_id: string;
  email_address: string;
  encrypted_refresh_token: string;
  history_id: string | null;
  watch_expires_at: number | null;
  connected_at: number;
  last_scan_at: number | null;
  last_error: string | null;
}

const accountColumns = `id, user_id, email_address, encrypted_refresh_token, history_id,
  watch_expires_at, connected_at, last_scan_at, last_error`;

export class GmailAccountStore {
  private readonly sql: SqlStorage;

  constructor(private readonly storage: DurableObjectStorage) {
    this.sql = storage.sql;
  }

  userIdForEmail(emailAddress: string): string | null {
    const row = this.sql.exec<{ user_id: string }>(
      "SELECT user_id FROM gmail_accounts WHERE email_address = ?",
      emailAddress.toLowerCase(),
    ).toArray()[0];
    return row?.user_id ?? null;
  }

  connect(
    linkUserId: string,
    emailAddress: string,
    encryptedRefreshToken: string,
    historyId: string | null,
    now = Date.now(),
  ): GmailConnectResult {
    return this.storage.transactionSync(() => {
      const normalizedEmail = emailAddress.toLowerCase();
      const existing = this.sql.exec<{ user_id: string }>(
        "SELECT user_id FROM gmail_accounts WHERE email_address = ?",
        normalizedEmail,
      ).toArray()[0];
      if (existing !== undefined && existing.user_id !== linkUserId) {
        return { status: "owner_conflict" };
      }
      if (existing === undefined) {
        const accountCount = this.sql.exec<{ count: number }>(
          "SELECT COUNT(*) AS count FROM gmail_accounts WHERE user_id = ?",
          linkUserId,
        ).toArray()[0]?.count ?? 0;
        if (accountCount >= 5) return { status: "account_limit" };
      }
      this.sql.exec("INSERT OR IGNORE INTO gmail_users (id, created_at) VALUES (?, ?)", linkUserId, now);
      this.sql.exec(
        `INSERT INTO gmail_accounts
           (id, user_id, email_address, encrypted_refresh_token, history_id, connected_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (email_address) DO UPDATE SET
           encrypted_refresh_token = excluded.encrypted_refresh_token,
           history_id = COALESCE(excluded.history_id, gmail_accounts.history_id),
           last_error = NULL,
           updated_at = excluded.updated_at`,
        crypto.randomUUID(),
        linkUserId,
        normalizedEmail,
        encryptedRefreshToken,
        historyId,
        now,
        now,
      );
      return { status: "connected", userId: linkUserId };
    });
  }

  beginManualScan(
    userId: string,
    now = Date.now(),
    cooldownMilliseconds = 10 * 60_000,
    leaseMilliseconds = 2 * 60_000,
  ): { accepted: boolean; retryAfter: number } {
    return this.storage.transactionSync(() => {
      const row = this.sql.exec<{ next_allowed_at: number; lease_until: number | null }>(
        "SELECT next_allowed_at, lease_until FROM gmail_manual_scan_state WHERE user_id = ?",
        userId,
      ).toArray()[0];
      const blockedUntil = Math.max(row?.next_allowed_at ?? 0, row?.lease_until ?? 0);
      if (blockedUntil > now) {
        return { accepted: false, retryAfter: Math.max(1, Math.ceil((blockedUntil - now) / 1_000)) };
      }
      this.sql.exec(
        `INSERT INTO gmail_manual_scan_state
           (user_id, next_allowed_at, lease_until, last_started_at, last_finished_at)
         VALUES (?, ?, ?, ?, NULL)
         ON CONFLICT (user_id) DO UPDATE SET
           next_allowed_at = excluded.next_allowed_at,
           lease_until = excluded.lease_until,
           last_started_at = excluded.last_started_at`,
        userId,
        now + cooldownMilliseconds,
        now + leaseMilliseconds,
        now,
      );
      return { accepted: true, retryAfter: 0 };
    });
  }

  finishManualScan(userId: string, now = Date.now()): void {
    this.sql.exec(
      "UPDATE gmail_manual_scan_state SET lease_until = NULL, last_finished_at = ? WHERE user_id = ?",
      now,
      userId,
    );
  }

  forUser(userId: string): GmailAccountSecret[] {
    return this.sql.exec<AccountRow>(
      `SELECT ${accountColumns} FROM gmail_accounts WHERE user_id = ? ORDER BY connected_at`,
      userId,
    ).toArray().map(accountSecret);
  }

  forEmail(emailAddress: string): GmailAccountSecret | null {
    const row = this.sql.exec<AccountRow>(
      `SELECT ${accountColumns} FROM gmail_accounts WHERE email_address = ?`,
      emailAddress.toLowerCase(),
    ).toArray()[0];
    return row === undefined ? null : accountSecret(row);
  }

  byId(accountId: string): GmailAccountSecret | null {
    const row = this.sql.exec<AccountRow>(
      `SELECT ${accountColumns} FROM gmail_accounts WHERE id = ?`,
      accountId,
    ).toArray()[0];
    return row === undefined ? null : accountSecret(row);
  }

  due(now = Date.now()): GmailAccountSecret[] {
    return this.sql.exec<AccountRow>(
      `SELECT ${accountColumns} FROM gmail_accounts
       WHERE last_scan_at IS NULL OR last_scan_at <= ?
       ORDER BY COALESCE(last_scan_at, 0) LIMIT 20`,
      now - 10 * 60_000,
    ).toArray().map(accountSecret);
  }

  connections(userId: string): GmailConnectionSummary[] {
    return this.sql.exec<AccountRow>(
      `SELECT ${accountColumns} FROM gmail_accounts WHERE user_id = ? ORDER BY connected_at`,
      userId,
    ).toArray().map((row) => ({
      id: row.id,
      emailAddress: row.email_address,
      connectedAt: new Date(row.connected_at).toISOString(),
      lastScanAt: row.last_scan_at === null ? null : new Date(row.last_scan_at).toISOString(),
      lastError: row.last_error,
    }));
  }

  recordScan(accountId: string, historyId: string | null, error: string | null, now = Date.now()): void {
    this.sql.exec(
      `UPDATE gmail_accounts SET history_id = COALESCE(?, history_id), last_scan_at = ?,
         last_error = ?, updated_at = ? WHERE id = ?`,
      historyId,
      now,
      error,
      now,
      accountId,
    );
  }

  recordWatch(accountId: string, historyId: string, expiresAt: number): void {
    this.sql.exec(
      "UPDATE gmail_accounts SET history_id = ?, watch_expires_at = ?, updated_at = ? WHERE id = ?",
      historyId,
      expiresAt,
      Date.now(),
      accountId,
    );
  }

  disconnect(userId: string, accountId: string): void {
    this.sql.exec("DELETE FROM gmail_accounts WHERE id = ? AND user_id = ?", accountId, userId);
  }
}

function accountSecret(row: AccountRow): GmailAccountSecret {
  return {
    id: row.id,
    userId: row.user_id,
    emailAddress: row.email_address,
    encryptedRefreshToken: row.encrypted_refresh_token,
    historyId: row.history_id,
    lastScanAt: row.last_scan_at,
    watchExpiresAt: row.watch_expires_at,
  };
}
