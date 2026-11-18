import type { MutationContext, MutationDecision } from "./mutation-security.js";

export function equalCredential(left: string, right: string): boolean {
  let difference = left.length ^ right.length;
  for (let i = 0; i < Math.max(left.length, right.length); i += 1) {
    difference |= (left.charCodeAt(i) || 0) ^ (right.charCodeAt(i) || 0);
  }
  return difference === 0;
}

/** This identity is independent of visible-alert enrollment, but shares its ownership credential. */
export function authorizeLiveActivity(sql: SqlStorage, installationId: string, context: MutationContext,
  operation: "register_live_activity" | "stop_live_activity", now: number): MutationDecision {
  const key = `${operation}:${context.clientKey}`;
  const window = sql.exec<{ window_started_at: number; request_count: number }>(
    "SELECT window_started_at, request_count FROM mutation_rate_windows WHERE key = ?", key,
  ).toArray()[0];
  if (window !== undefined && now - window.window_started_at < 60_000 && window.request_count >= 30) {
    return { allowed: false, reason: "rate_limited", retryAfterSeconds: Math.max(1,
      Math.ceil((window.window_started_at + 60_000 - now) / 1_000)) };
  }
  if (window === undefined || now - window.window_started_at >= 60_000) {
    sql.exec(`INSERT INTO mutation_rate_windows (key, window_started_at, request_count, updated_at)
      VALUES (?, ?, 1, ?) ON CONFLICT (key) DO UPDATE SET
      window_started_at = excluded.window_started_at, request_count = 1, updated_at = excluded.updated_at`, key, now, now);
  } else sql.exec("UPDATE mutation_rate_windows SET request_count = request_count + 1, updated_at = ? WHERE key = ?", now, key);
  sql.exec("DELETE FROM mutation_rate_windows WHERE updated_at < ?", now - 86_400_000);

  const device = sql.exec<{ credential_hash: string | null }>(
    "SELECT credential_hash FROM devices WHERE installation_id = ?", installationId,
  ).toArray()[0];
  const identity = sql.exec<{ credential_hash: string }>(
    "SELECT credential_hash FROM live_activity_installations WHERE installation_id = ?", installationId,
  ).toArray()[0];
  if ((device !== undefined && (device.credential_hash === null || !equalCredential(device.credential_hash, context.credentialHash)))
    || (identity !== undefined && !equalCredential(identity.credential_hash, context.credentialHash))) {
    return { allowed: false, reason: "unauthorized" };
  }
  sql.exec(`INSERT INTO live_activity_installations (installation_id, credential_hash, created_at, updated_at)
    VALUES (?, ?, ?, ?) ON CONFLICT (installation_id) DO UPDATE SET updated_at = excluded.updated_at`,
  installationId, context.credentialHash, now, now);
  return { allowed: true };
}
