const encoder = new TextEncoder();

export function base64URL(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/gu, "-").replace(/\//gu, "_").replace(/=+$/gu, "");
}

export function randomToken(bytes = 32): string {
  const values = new Uint8Array(bytes);
  crypto.getRandomValues(values);
  return base64URL(values);
}

export async function sha256(value: string): Promise<string> {
  return base64URL(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value))));
}

async function encryptionKey(secret: string): Promise<CryptoKey> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(secret));
  return crypto.subtle.importKey("raw", digest, "AES-GCM", false, ["encrypt", "decrypt"]);
}

export async function encryptSecret(value: string, secret: string): Promise<string> {
  const nonce = new Uint8Array(12);
  crypto.getRandomValues(nonce);
  const encrypted = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: nonce },
    await encryptionKey(secret),
    encoder.encode(value),
  );
  const packed = new Uint8Array(nonce.length + encrypted.byteLength);
  packed.set(nonce);
  packed.set(new Uint8Array(encrypted), nonce.length);
  return base64URL(packed);
}

export async function decryptSecret(value: string, secret: string): Promise<string> {
  const normalized = value.replace(/-/gu, "+").replace(/_/gu, "/");
  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
  const binary = atob(padded);
  const packed = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  const decrypted = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: packed.slice(0, 12) },
    await encryptionKey(secret),
    packed.slice(12),
  );
  return new TextDecoder().decode(decrypted);
}
