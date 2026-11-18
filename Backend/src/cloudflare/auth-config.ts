import type { WorkerEnv } from "./env.js";

/**
 * Account auth encrypts refresh tokens with its own key, preferring
 * `AUTH_TOKEN_ENCRYPTION_KEY` so account auth is no longer named as a Gmail
 * dependency. `GMAIL_TOKEN_ENCRYPTION_KEY` remains a fallback for existing
 * deployments that only ever set the Gmail-named secret.
 */
export function authEncryptionKey(env: WorkerEnv): string | undefined {
  return env.AUTH_TOKEN_ENCRYPTION_KEY ?? env.GMAIL_TOKEN_ENCRYPTION_KEY;
}
