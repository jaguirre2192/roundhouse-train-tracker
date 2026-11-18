import type { GmailOAuthState } from "./gmail-models.js";

interface OAuthRow extends Record<string, SqlStorageValue> {
  verifier: string;
  link_user_id: string;
  transaction_id: string;
  app_challenge: string;
  expires_at: number;
}

export class GmailOAuthStore {
  private readonly sql: SqlStorage;

  constructor(private readonly storage: DurableObjectStorage) {
    this.sql = storage.sql;
  }

  createState(
    stateHash: string,
    verifier: string,
    linkUserId: string,
    transactionId: string,
    appChallenge: string,
    expiresAt: number,
    now = Date.now(),
  ): boolean {
    return this.storage.transactionSync(() => {
      this.sql.exec("DELETE FROM gmail_oauth_states WHERE expires_at < ?", now);
      const pending = this.sql.exec<{ count: number }>(
        "SELECT COUNT(*) AS count FROM gmail_oauth_states WHERE link_user_id = ? AND expires_at >= ?",
        linkUserId,
        now,
      ).toArray()[0]?.count ?? 0;
      if (pending >= 3) return false;
      this.sql.exec(
        `INSERT INTO gmail_oauth_states
           (state_hash, verifier, link_user_id, transaction_id, app_challenge, expires_at)
         VALUES (?, ?, ?, ?, ?, ?)`,
        stateHash,
        verifier,
        linkUserId,
        transactionId,
        appChallenge,
        expiresAt,
      );
      return true;
    });
  }

  consumeState(stateHash: string, now = Date.now()): GmailOAuthState | null {
    return this.storage.transactionSync(() => {
      const row = this.sql.exec<OAuthRow>(
        `SELECT verifier, link_user_id, transaction_id, app_challenge, expires_at
         FROM gmail_oauth_states WHERE state_hash = ?`,
        stateHash,
      ).toArray()[0];
      this.sql.exec("DELETE FROM gmail_oauth_states WHERE state_hash = ?", stateHash);
      if (row === undefined || row.expires_at < now) return null;
      return {
        verifier: row.verifier,
        linkUserId: row.link_user_id,
        transactionId: row.transaction_id,
        appChallenge: row.app_challenge,
      };
    });
  }

  userIdForSession(sessionHash: string, now = Date.now()): string | null {
    const row = this.sql.exec<{ user_id: string; expires_at: number }>(
      "SELECT user_id, expires_at FROM gmail_sessions WHERE token_hash = ?",
      sessionHash,
    ).toArray()[0];
    if (row === undefined || row.expires_at < now) return null;
    this.sql.exec("UPDATE gmail_sessions SET last_used_at = ? WHERE token_hash = ?", now, sessionHash);
    return row.user_id;
  }

  createExchangeCode(
    codeHash: string,
    userId: string,
    transactionId: string,
    appChallenge: string,
    expiresAt: number,
  ): void {
    this.sql.exec(
      `INSERT INTO gmail_exchange_codes
         (code_hash, user_id, transaction_id, app_challenge, expires_at)
       VALUES (?, ?, ?, ?, ?)`,
      codeHash,
      userId,
      transactionId,
      appChallenge,
      expiresAt,
    );
  }

  completeConnection(
    codeHash: string,
    transactionId: string,
    presentedChallenge: string,
    authenticatedUserId: string,
    now = Date.now(),
  ): boolean {
    return this.storage.transactionSync(() => {
      const row = this.sql.exec<{
        user_id: string;
        transaction_id: string | null;
        app_challenge: string | null;
        expires_at: number;
      }>(
        `SELECT user_id, transaction_id, app_challenge, expires_at
         FROM gmail_exchange_codes WHERE code_hash = ?`,
        codeHash,
      ).toArray()[0];
      if (row === undefined) return false;
      if (row.expires_at < now) {
        this.sql.exec("DELETE FROM gmail_exchange_codes WHERE code_hash = ?", codeHash);
        return false;
      }
      if (row.user_id !== authenticatedUserId || row.transaction_id !== transactionId
        || row.app_challenge !== presentedChallenge) return false;
      this.sql.exec("DELETE FROM gmail_exchange_codes WHERE code_hash = ?", codeHash);
      return true;
    });
  }

  exchangeSession(
    codeHash: string,
    sessionHash: string,
    sessionExpiresAt: number,
    now = Date.now(),
  ): boolean {
    return this.storage.transactionSync(() => {
      const row = this.sql.exec<{ user_id: string; expires_at: number }>(
        "SELECT user_id, expires_at FROM gmail_exchange_codes WHERE code_hash = ?",
        codeHash,
      ).toArray()[0];
      this.sql.exec("DELETE FROM gmail_exchange_codes WHERE code_hash = ?", codeHash);
      if (row === undefined || row.expires_at < now) return false;
      this.sql.exec(
        `INSERT INTO gmail_sessions (token_hash, user_id, expires_at, created_at, last_used_at)
         VALUES (?, ?, ?, ?, ?)`,
        sessionHash,
        row.user_id,
        sessionExpiresAt,
        now,
        now,
      );
      return true;
    });
  }
}
