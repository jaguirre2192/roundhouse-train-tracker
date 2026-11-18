function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

function encodedJSON(value: object): string {
  return base64url(new TextEncoder().encode(JSON.stringify(value)));
}

function privateKeyBytes(value: string): Uint8Array {
  const normalized = value.replaceAll("\\n", "\n").trim();
  const encoded = normalized.includes("BEGIN PRIVATE KEY")
    ? normalized
        .replace("-----BEGIN PRIVATE KEY-----", "")
        .replace("-----END PRIVATE KEY-----", "")
        .replace(/\s+/gu, "")
    : normalized.replace(/\s+/gu, "");
  const binary = atob(encoded);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

export interface APNsProviderTokenConfig {
  teamId: string;
  keyId: string;
  privateKey: string;
}

export class APNsProviderToken {
  private cached: { value: string; issuedAt: number } | null = null;
  private key: Promise<CryptoKey> | null = null;

  constructor(private readonly config: APNsProviderTokenConfig) {}

  async value(now = Math.floor(Date.now() / 1_000)): Promise<string> {
    if (this.cached !== null && now - this.cached.issuedAt < 20 * 60) return this.cached.value;

    const header = encodedJSON({ alg: "ES256", kid: this.config.keyId });
    const claims = encodedJSON({ iss: this.config.teamId, iat: now });
    const unsigned = `${header}.${claims}`;
    const signature = new Uint8Array(await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      await this.privateKey(),
      new TextEncoder().encode(unsigned),
    ));
    if (signature.byteLength !== 64) throw new Error("APNs ES256 signature was not 64 bytes");

    const value = `${unsigned}.${base64url(signature)}`;
    this.cached = { value, issuedAt: now };
    return value;
  }

  private privateKey(): Promise<CryptoKey> {
    this.key ??= crypto.subtle.importKey(
      "pkcs8",
      privateKeyBytes(this.config.privateKey).buffer as ArrayBuffer,
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["sign"],
    );
    return this.key;
  }
}
