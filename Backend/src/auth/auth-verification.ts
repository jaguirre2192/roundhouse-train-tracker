import {
  createRemoteJWKSet,
  importPKCS8,
  jwtVerify,
  SignJWT,
} from "jose";
import type { VerifiedIdentity } from "./auth-models.js";

const googleKeys = createRemoteJWKSet(new URL("https://www.googleapis.com/oauth2/v3/certs"));
const appleKeys = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));

function verifiedBoolean(value: unknown): boolean {
  return value === true || value === "true";
}

function requiredSubject(subject: unknown): string {
  if (typeof subject !== "string" || subject.length < 3 || subject.length > 500) {
    throw new Error("Identity token did not contain a valid subject");
  }
  return subject;
}

export async function verifyGoogleIdentity(
  idToken: string,
  clientId: string,
): Promise<VerifiedIdentity> {
  const { payload } = await jwtVerify(idToken, googleKeys, {
    issuer: ["accounts.google.com", "https://accounts.google.com"],
    audience: clientId,
  });
  const email = typeof payload.email === "string" ? payload.email.toLowerCase() : null;
  return {
    provider: "google",
    subject: requiredSubject(payload.sub),
    email,
    emailVerified: verifiedBoolean(payload.email_verified),
    displayName: typeof payload.name === "string" ? payload.name.slice(0, 200) : null,
    clientId,
  };
}

export async function verifyAppleIdentity(
  identityToken: string,
  rawNonceHash: string,
  allowedClientIds: string[],
  displayName: string | null,
): Promise<VerifiedIdentity> {
  const { payload } = await jwtVerify(identityToken, appleKeys, {
    issuer: "https://appleid.apple.com",
    audience: allowedClientIds,
  });
  if (payload.nonce !== rawNonceHash) throw new Error("Apple sign-in nonce did not match");
  const clientId = Array.isArray(payload.aud) ? payload.aud[0] : payload.aud;
  if (typeof clientId !== "string" || !allowedClientIds.includes(clientId)) {
    throw new Error("Apple sign-in audience was not recognized");
  }
  const email = typeof payload.email === "string" ? payload.email.toLowerCase() : null;
  return {
    provider: "apple",
    subject: requiredSubject(payload.sub),
    email,
    emailVerified: verifiedBoolean(payload.email_verified),
    displayName: displayName?.slice(0, 200) ?? null,
    clientId,
  };
}

export interface AppleOAuthConfiguration {
  teamId: string;
  keyId: string;
  privateKey: string;
}

async function appleClientSecret(
  configuration: AppleOAuthConfiguration,
  clientId: string,
): Promise<string> {
  const key = await importPKCS8(configuration.privateKey.replace(/\\n/gu, "\n"), "ES256");
  return new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: configuration.keyId })
    .setIssuer(configuration.teamId)
    .setSubject(clientId)
    .setAudience("https://appleid.apple.com")
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(key);
}

export async function exchangeAppleAuthorizationCode(
  configuration: AppleOAuthConfiguration,
  clientId: string,
  authorizationCode: string,
): Promise<string | null> {
  const response = await fetch("https://appleid.apple.com/auth/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: clientId,
      client_secret: await appleClientSecret(configuration, clientId),
      code: authorizationCode,
      grant_type: "authorization_code",
    }),
  });
  if (!response.ok) throw new Error(`Apple authorization-code exchange failed (${response.status})`);
  const value = await response.json() as { refresh_token?: string };
  return value.refresh_token ?? null;
}

export async function revokeAppleRefreshToken(
  configuration: AppleOAuthConfiguration,
  clientId: string,
  refreshToken: string,
): Promise<void> {
  const response = await fetch("https://appleid.apple.com/auth/revoke", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: clientId,
      client_secret: await appleClientSecret(configuration, clientId),
      token: refreshToken,
      token_type_hint: "refresh_token",
    }),
  });
  if (!response.ok) throw new Error(`Apple token revocation failed (${response.status})`);
}
