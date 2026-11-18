import { describe, expect, it } from "vitest";
import { APNsProviderToken } from "../src/cloudflare/apns-provider-token.js";

function base64urlBytes(value: string): Uint8Array {
  const base64 = value.replaceAll("-", "+").replaceAll("_", "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  return Uint8Array.from(atob(base64), (character) => character.charCodeAt(0));
}

function pem(value: ArrayBuffer): string {
  const bytes = new Uint8Array(value);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  const encoded = btoa(binary).match(/.{1,64}/gu)?.join("\n") ?? "";
  return `-----BEGIN PRIVATE KEY-----\n${encoded}\n-----END PRIVATE KEY-----\n`;
}

describe("APNsProviderToken", () => {
  it("creates and caches a verifiable ES256 JWT", async () => {
    const pair = await crypto.subtle.generateKey(
      { name: "ECDSA", namedCurve: "P-256" },
      true,
      ["sign", "verify"],
    ) as CryptoKeyPair;
    const privateKey = pem(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
    const providerToken = new APNsProviderToken({
      teamId: "EXAMPLETEAM",
      keyId: "EXAMPLEKEY1",
      privateKey,
    });

    const token = await providerToken.value(1_784_570_000);
    expect(await providerToken.value(1_784_570_100)).toBe(token);
    const [header, claims, signature] = token.split(".");
    expect(header).toBeDefined();
    expect(claims).toBeDefined();
    expect(signature).toBeDefined();
    const verified = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      pair.publicKey,
      base64urlBytes(signature!).buffer as ArrayBuffer,
      new TextEncoder().encode(`${header}.${claims}`),
    );
    expect(verified).toBe(true);
  });
});
