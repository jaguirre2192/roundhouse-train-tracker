import { createHash, timingSafeEqual } from "node:crypto";

const credentialPattern = /^[A-Za-z0-9_-]{43}$/u;

/// SHA-256 of a well-formed `Device <credential>` header, or null. Shared by the
/// Worker and the self-hosted Node API so both enforce the same possession model.
export function deviceCredentialHash(authorization: string | null | undefined): string | null {
  const [scheme, credential, ...extra] = (authorization?.trim() ?? "").split(/\s+/u);
  if (scheme !== "Device" || credential === undefined || extra.length > 0
    || !credentialPattern.test(credential)) return null;
  return createHash("sha256").update(credential).digest("hex");
}

export function equalCredentialHash(stored: string | null, presented: string): boolean {
  if (stored === null) return false;
  const left = Buffer.from(stored);
  const right = Buffer.from(presented);
  return left.length === right.length && timingSafeEqual(left, right);
}
