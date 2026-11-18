const encoder = new TextEncoder();

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

// Non-secret alias nonce persisted per user. It is combined with the server
// secret via HMAC to deterministically re-derive the forwarding token on
// every read, so a lost/reinstalled client can recover its address without
// the raw token ever being written to storage.
export function randomAliasNonce(bytes = 20): string {
  const values = new Uint8Array(bytes);
  crypto.getRandomValues(values);
  return toHex(values);
}

/**
 * Deterministically derives the 40-lowercase-hex alias token from the stored
 * nonce, the owning user, and the target domain, using HMAC-SHA256 keyed by
 * a server-only secret. Truncating the 32-byte MAC to its first 20 bytes
 * still leaves 160 bits of unguessable output — the same size as the
 * previous purely-random token — while making the token reconstructable
 * without persisting it.
 */
export async function deriveAliasToken(
  secret: string,
  nonce: string,
  userId: string,
  domain: string,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const message = `train-tracker:ticket-forwarding-alias:${domain}:${userId}:${nonce}`;
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(message)));
  return toHex(signature.slice(0, 20));
}
