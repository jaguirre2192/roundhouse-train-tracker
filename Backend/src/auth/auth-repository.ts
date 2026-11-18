import type {
  AppUserSummary,
  AppleRefreshCredential,
  AuthProvider,
  GoogleAuthState,
  VerifiedIdentity,
} from "./auth-models.js";
import { isStorageWriteQuotaExceeded } from "../cloudflare/storage-availability.js";

interface GoogleStateRow extends Record<string, SqlStorageValue> {
  verifier: string;
  transaction_id: string;
  app_challenge: string;
  expected_user_id: string | null;
  expires_at: number;
}

interface IdentityRow extends Record<string, SqlStorageValue> {
  user_id: string;
}

interface ProfileRow extends Record<string, SqlStorageValue> {
  id: string;
  email: string | null;
  display_name: string | null;
}

export class AuthRepository {
  private readonly sql: SqlStorage;

  constructor(private readonly storage: DurableObjectStorage) {
    this.sql = storage.sql;
  }

  createGoogleState(
    stateHash: string,
    verifier: string,
    transactionId: string,
    appChallenge: string,
    expectedUserId: string | null,
    expiresAt: number,
  ): void {
    const now = Date.now();
    this.storage.transactionSync(() => {
      this.sql.exec("DELETE FROM auth_google_states WHERE expires_at < ?", now);
      this.sql.exec(
        `INSERT INTO auth_google_states
           (state_hash, verifier, transaction_id, app_challenge, expected_user_id, expires_at)
         VALUES (?, ?, ?, ?, ?, ?)`,
        stateHash,
        verifier,
        transactionId,
        appChallenge,
        expectedUserId,
        expiresAt,
      );
    });
  }

  consumeGoogleState(stateHash: string, now = Date.now()): GoogleAuthState | null {
    return this.storage.transactionSync(() => {
      const row = this.sql.exec<GoogleStateRow>(
        `SELECT verifier, transaction_id, app_challenge, expected_user_id, expires_at
         FROM auth_google_states WHERE state_hash = ?`,
        stateHash,
      ).toArray()[0];
      this.sql.exec("DELETE FROM auth_google_states WHERE state_hash = ?", stateHash);
      if (row === undefined || row.expires_at < now) return null;
      return {
        verifier: row.verifier,
        transactionId: row.transaction_id,
        appChallenge: row.app_challenge,
        expectedUserId: row.expected_user_id,
      };
    });
  }

  resolveIdentity(
    identity: VerifiedIdentity,
    expectedUserId: string | null,
    encryptedRefreshToken: string | null,
    now = Date.now(),
  ): string | null {
    return this.storage.transactionSync(() => {
      const existing = this.sql.exec<IdentityRow>(
        "SELECT user_id FROM app_identities WHERE provider = ? AND subject = ?",
        identity.provider,
        identity.subject,
      ).toArray()[0];
      if (existing !== undefined) {
        if (expectedUserId !== null && existing.user_id !== expectedUserId) return null;
        this.updateIdentity(existing.user_id, identity, encryptedRefreshToken, now);
        return existing.user_id;
      }

      const matchedUserId = expectedUserId ?? this.userIdForVerifiedEmail(identity);
      const userId = matchedUserId ?? crypto.randomUUID();
      this.sql.exec("INSERT OR IGNORE INTO gmail_users (id, created_at) VALUES (?, ?)", userId, now);
      this.sql.exec(
        `INSERT INTO app_profiles (user_id, email, display_name, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT (user_id) DO UPDATE SET
           email = COALESCE(app_profiles.email, excluded.email),
           display_name = COALESCE(app_profiles.display_name, excluded.display_name),
           updated_at = excluded.updated_at`,
        userId,
        identity.emailVerified ? identity.email : null,
        identity.displayName,
        now,
        now,
      );
      this.sql.exec(
        `INSERT INTO app_identities
           (id, user_id, provider, subject, email, display_name, client_id,
            encrypted_refresh_token, created_at, last_login_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        crypto.randomUUID(),
        userId,
        identity.provider,
        identity.subject,
        identity.email,
        identity.displayName,
        identity.clientId,
        encryptedRefreshToken,
        now,
        now,
      );
      return userId;
    });
  }

  createExchangeCode(
    codeHash: string,
    userId: string,
    transactionId: string,
    appChallenge: string,
    expiresAt: number,
  ): void {
    this.sql.exec(
      `INSERT INTO auth_exchange_codes
         (code_hash, user_id, transaction_id, app_challenge, expires_at)
       VALUES (?, ?, ?, ?, ?)`,
      codeHash,
      userId,
      transactionId,
      appChallenge,
      expiresAt,
    );
  }

  exchangeSession(
    codeHash: string,
    transactionId: string,
    presentedChallenge: string,
    sessionHash: string,
    sessionExpiresAt: number,
    now = Date.now(),
  ): AppUserSummary | null {
    return this.storage.transactionSync(() => {
      const row = this.sql.exec<{
        user_id: string;
        transaction_id: string;
        app_challenge: string;
        expires_at: number;
      }>(
        `SELECT user_id, transaction_id, app_challenge, expires_at
         FROM auth_exchange_codes WHERE code_hash = ?`,
        codeHash,
      ).toArray()[0];
      if (row === undefined || row.expires_at < now || row.transaction_id !== transactionId
        || row.app_challenge !== presentedChallenge) return null;
      this.sql.exec("DELETE FROM auth_exchange_codes WHERE code_hash = ?", codeHash);
      this.insertSession(row.user_id, sessionHash, sessionExpiresAt, now);
      return this.user(row.user_id);
    });
  }

  createSession(userId: string, tokenHash: string, expiresAt: number, now = Date.now()): AppUserSummary {
    this.insertSession(userId, tokenHash, expiresAt, now);
    return this.user(userId);
  }

  userIdForSession(tokenHash: string, now = Date.now()): string | null {
    const row = this.sql.exec<{ user_id: string; expires_at: number; last_used_at: number }>(
      "SELECT user_id, expires_at, last_used_at FROM app_sessions WHERE token_hash = ?",
      tokenHash,
    ).toArray()[0];
    if (row === undefined || row.expires_at <= now) return null;
    // Session expiry is absolute. Keep an approximate activity timestamp without a storage
    // write for every authenticated read, including access to saved tickets.
    if (row.last_used_at < now - 86_400_000) {
      try {
        this.sql.exec("UPDATE app_sessions SET last_used_at = ? WHERE token_hash = ?", now, tokenHash);
      } catch (error) {
        if (!isStorageWriteQuotaExceeded(error)) throw error;
      }
    }
    return row.user_id;
  }

  userForSession(tokenHash: string): AppUserSummary | null {
    const userId = this.userIdForSession(tokenHash);
    return userId === null ? null : this.user(userId);
  }

  revokeSession(tokenHash: string): void {
    this.sql.exec("DELETE FROM app_sessions WHERE token_hash = ?", tokenHash);
  }

  appleRefreshCredentials(userId: string): AppleRefreshCredential[] {
    return this.sql.exec<{ encrypted_refresh_token: string; client_id: string }>(
      `SELECT encrypted_refresh_token, client_id FROM app_identities
       WHERE user_id = ? AND provider = 'apple' AND encrypted_refresh_token IS NOT NULL`,
      userId,
    ).toArray().map((row) => ({
      encryptedRefreshToken: row.encrypted_refresh_token,
      clientId: row.client_id,
    }));
  }

  deleteUser(userId: string): void {
    this.sql.exec("DELETE FROM gmail_users WHERE id = ?", userId);
  }

  private userIdForVerifiedEmail(identity: VerifiedIdentity): string | null {
    if (!identity.emailVerified || identity.email === null) return null;
    const profile = this.sql.exec<{ user_id: string }>(
      "SELECT user_id FROM app_profiles WHERE lower(email) = lower(?) LIMIT 1",
      identity.email,
    ).toArray()[0];
    if (profile !== undefined) return profile.user_id;
    return this.sql.exec<{ user_id: string }>(
      "SELECT user_id FROM gmail_accounts WHERE lower(email_address) = lower(?) LIMIT 1",
      identity.email,
    ).toArray()[0]?.user_id ?? null;
  }

  private updateIdentity(
    userId: string,
    identity: VerifiedIdentity,
    encryptedRefreshToken: string | null,
    now: number,
  ): void {
    this.sql.exec(
      `UPDATE app_identities SET email = COALESCE(?, email), display_name = COALESCE(?, display_name),
         client_id = ?, encrypted_refresh_token = COALESCE(?, encrypted_refresh_token), last_login_at = ?
       WHERE provider = ? AND subject = ?`,
      identity.email,
      identity.displayName,
      identity.clientId,
      encryptedRefreshToken,
      now,
      identity.provider,
      identity.subject,
    );
    this.sql.exec(
      `INSERT INTO app_profiles (user_id, email, display_name, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?)
       ON CONFLICT (user_id) DO UPDATE SET
         email = COALESCE(app_profiles.email, excluded.email),
         display_name = COALESCE(app_profiles.display_name, excluded.display_name),
         updated_at = excluded.updated_at`,
      userId,
      identity.emailVerified ? identity.email : null,
      identity.displayName,
      now,
      now,
    );
  }

  private insertSession(userId: string, tokenHash: string, expiresAt: number, now: number): void {
    this.sql.exec(
      `INSERT INTO app_sessions (token_hash, user_id, expires_at, created_at, last_used_at)
       VALUES (?, ?, ?, ?, ?)`,
      tokenHash,
      userId,
      expiresAt,
      now,
      now,
    );
  }

  private user(userId: string): AppUserSummary {
    const profile = this.sql.exec<ProfileRow>(
      `SELECT gmail_users.id, app_profiles.email, app_profiles.display_name
       FROM gmail_users LEFT JOIN app_profiles ON app_profiles.user_id = gmail_users.id
       WHERE gmail_users.id = ?`,
      userId,
    ).toArray()[0];
    if (profile === undefined) throw new Error("Account profile was not found");
    const providers = this.sql.exec<{ provider: AuthProvider }>(
      "SELECT provider FROM app_identities WHERE user_id = ? ORDER BY provider",
      userId,
    ).toArray().map((row) => row.provider);
    return { id: profile.id, email: profile.email, displayName: profile.display_name, providers };
  }
}
