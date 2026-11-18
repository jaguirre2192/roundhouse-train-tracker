import { exchangeGoogleCode, googleAuthorizationURL } from "../auth/auth-oauth.js";
import {
  exchangeAppleAuthorizationCode,
  revokeAppleRefreshToken,
  verifyAppleIdentity,
  verifyGoogleIdentity,
  type AppleOAuthConfiguration,
} from "../auth/auth-verification.js";
import { randomToken, sha256 } from "../gmail/gmail-crypto.js";
import type { WorkerEnv } from "./env.js";
import { authenticatedUserId, bearerToken } from "./request-session.js";
import { boundedJSONBody, maximumJSONBodyBytes, RequestBodyTooLargeError } from "./http.js";
import { authConnectedPage } from "./public-pages.js";
import type { TrainTrackerWatcher } from "./watcher-object.js";

const sessionLifetime = 90 * 24 * 60 * 60_000;

function json(value: unknown, status = 200): Response {
  return Response.json(value, { status, headers: { "cache-control": "no-store" } });
}

async function requestBody(request: Request): Promise<Record<string, unknown> | null> {
  try {
    const value = await boundedJSONBody(request, maximumJSONBodyBytes);
    return typeof value === "object" && value !== null && !Array.isArray(value)
      ? value as Record<string, unknown>
      : null;
  } catch (error) {
    if (error instanceof RequestBodyTooLargeError) throw error;
    return null;
  }
}

function boundedString(value: unknown, minimum: number, maximum: number): string | null {
  return typeof value === "string" && value.length >= minimum && value.length <= maximum
    ? value
    : null;
}

function googleConfiguration(env: WorkerEnv, origin: string) {
  const clientId = env.GOOGLE_AUTH_CLIENT_ID ?? env.GMAIL_OAUTH_CLIENT_ID;
  const clientSecret = env.GOOGLE_AUTH_CLIENT_SECRET ?? env.GMAIL_OAUTH_CLIENT_SECRET;
  if (clientId === undefined || clientSecret === undefined) return null;
  return { clientId, clientSecret, redirectURI: `${origin}/v1/auth/google/callback` };
}

function appleConfiguration(env: WorkerEnv): AppleOAuthConfiguration | null {
  if (env.APPLE_TEAM_ID === undefined || env.APPLE_KEY_ID === undefined
    || env.APPLE_PRIVATE_KEY === undefined) return null;
  return { teamId: env.APPLE_TEAM_ID, keyId: env.APPLE_KEY_ID, privateKey: env.APPLE_PRIVATE_KEY };
}

function appleClientIds(env: WorkerEnv): string[] {
  return [env.APPLE_IOS_CLIENT_ID, env.APPLE_MACOS_CLIENT_ID]
    .filter((value): value is string => value !== undefined && value.length > 0);
}

async function enforceGoogleAuthStartRateLimit(
  request: Request,
  env: WorkerEnv,
): Promise<Response | null> {
  const limiter = env.GOOGLE_AUTH_START_RATE_LIMIT;
  if (limiter === undefined) {
    const hostname = new URL(request.url).hostname;
    if (hostname === "localhost" || hostname === "127.0.0.1" || hostname === "::1"
      || hostname.endsWith(".test")) return null;
    console.error("auth_rate_limit_metric", {
      operation: "google_auth_start",
      outcome: "limiter_unavailable",
    });
    return json({ error: "service_unavailable" }, 503);
  }

  const address = request.headers.get("cf-connecting-ip")?.trim();
  if (address === undefined || address.length === 0) {
    const hostname = new URL(request.url).hostname;
    if (hostname === "localhost" || hostname === "127.0.0.1" || hostname === "::1"
      || hostname.endsWith(".test")) return null;
    console.error("auth_rate_limit_metric", {
      operation: "google_auth_start",
      outcome: "missing_client_address",
    });
    return json({ error: "service_unavailable" }, 503);
  }

  try {
    const { success } = await limiter.limit({ key: `google-auth-start:${address}` });
    if (success) return null;
    console.warn("auth_rate_limit_metric", {
      operation: "google_auth_start",
      outcome: "rate_limited",
    });
    return Response.json(
      { error: "rate_limited" },
      { status: 429, headers: { "cache-control": "no-store", "retry-after": "60" } },
    );
  } catch {
    console.error("auth_rate_limit_metric", {
      operation: "google_auth_start",
      outcome: "limiter_unavailable",
    });
    return json({ error: "service_unavailable" }, 503);
  }
}

export function googleAppCallbackURL(exchangeCode: string, transactionId: string): string {
  const callback = new URL("traintracker://auth-connected");
  callback.searchParams.set("code", exchangeCode);
  callback.searchParams.set("transaction", transactionId);
  return callback.toString();
}

export async function handleAuthRequest(
  request: Request,
  env: WorkerEnv,
  watcher: DurableObjectStub<TrainTrackerWatcher>,
  url: URL,
  path: string,
): Promise<Response | null> {
  if (request.method === "GET" && path === "/auth-connected") {
    const code = boundedString(url.searchParams.get("code"), 20, 500);
    const transactionId = boundedString(url.searchParams.get("transaction"), 16, 200);
    return code === null || transactionId === null
      ? json({ error: "invalid_exchange_code" }, 400)
      : authConnectedPage(code, transactionId);
  }

  if (request.method === "GET" && path === "/v1/auth/status") {
    const google = googleConfiguration(env, url.origin) !== null && await watcher.authAvailable();
    const apple = appleConfiguration(env) !== null && appleClientIds(env).length > 0
      && await watcher.authAvailable();
    return json({ available: google || apple, apple, google });
  }

  if (request.method === "POST" && path === "/v1/auth/google/start") {
    const rateLimitResponse = await enforceGoogleAuthStartRateLimit(request, env);
    if (rateLimitResponse !== null) return rateLimitResponse;

    const configuration = googleConfiguration(env, url.origin);
    if (configuration === null || !await watcher.authAvailable()) {
      return json({ error: "google_sign_in_unavailable" }, 503);
    }
    const body = await requestBody(request);
    const transactionId = boundedString(body?.transactionId, 16, 200);
    const appChallenge = boundedString(body?.challenge, 43, 100);
    if (transactionId === null || appChallenge === null) return json({ error: "invalid_request" }, 400);
    const presented = bearerToken(request);
    const expectedUserId = presented === null ? null : await authenticatedUserId(request, watcher);
    if (presented !== null && expectedUserId === null) return json({ error: "unauthorized" }, 401);
    const state = randomToken();
    const verifier = randomToken(48);
    await watcher.createGoogleAuthState(
      await sha256(state),
      verifier,
      transactionId,
      appChallenge,
      expectedUserId,
      Date.now() + 10 * 60_000,
    );
    return json({ url: googleAuthorizationURL(configuration, state, await sha256(verifier)).toString() });
  }

  if (request.method === "GET" && path === "/v1/auth/google/callback") {
    const configuration = googleConfiguration(env, url.origin);
    if (configuration === null) return json({ error: "google_sign_in_unavailable" }, 503);
    const state = boundedString(url.searchParams.get("state"), 20, 500);
    const code = boundedString(url.searchParams.get("code"), 3, 2_000);
    if (state === null || code === null) return json({ error: "invalid_oauth_callback" }, 400);
    const pending = await watcher.consumeGoogleAuthState(await sha256(state));
    if (pending === null) return json({ error: "oauth_state_expired" }, 400);
    const token = await exchangeGoogleCode(configuration, code, pending.verifier);
    const identity = await verifyGoogleIdentity(token.id_token, configuration.clientId);
    if (!identity.emailVerified) return json({ error: "google_email_unverified" }, 400);
    const userId = await watcher.resolveAuthIdentity(identity, pending.expectedUserId, null);
    if (userId === null) return json({ error: "account_identity_conflict" }, 409);
    const exchangeCode = randomToken();
    await watcher.createAuthExchangeCode(
      await sha256(exchangeCode),
      userId,
      pending.transactionId,
      pending.appChallenge,
      Date.now() + 5 * 60_000,
    );
    return new Response(null, {
      status: 303,
      headers: {
        location: googleAppCallbackURL(exchangeCode, pending.transactionId),
        "cache-control": "no-store",
      },
    });
  }

  if (request.method === "POST" && path === "/v1/auth/session/exchange") {
    const body = await requestBody(request);
    const code = boundedString(body?.code, 20, 500);
    const transactionId = boundedString(body?.transactionId, 16, 200);
    const verifier = boundedString(body?.verifier, 32, 500);
    if (code === null || transactionId === null || verifier === null) {
      return json({ error: "invalid_exchange" }, 400);
    }
    const session = randomToken(48);
    const user = await watcher.exchangeAuthSession(
      await sha256(code),
      transactionId,
      await sha256(verifier),
      await sha256(session),
      Date.now() + sessionLifetime,
    );
    return user === null ? json({ error: "exchange_expired" }, 400) : json({ token: session, user });
  }

  if (request.method === "POST" && path === "/v1/auth/apple") {
    const configuration = appleConfiguration(env);
    const clientIds = appleClientIds(env);
    if (configuration === null || clientIds.length === 0 || !await watcher.authAvailable()) {
      return json({ error: "apple_sign_in_unavailable" }, 503);
    }
    const body = await requestBody(request);
    const identityToken = boundedString(body?.identityToken, 100, 20_000);
    const authorizationCode = boundedString(body?.authorizationCode, 3, 5_000);
    const rawNonce = boundedString(body?.rawNonce, 20, 500);
    const fullName = boundedString(body?.fullName, 1, 200);
    if (identityToken === null || authorizationCode === null || rawNonce === null) {
      return json({ error: "invalid_apple_credential" }, 400);
    }
    const requestId = crypto.randomUUID();
    let identity: Awaited<ReturnType<typeof verifyAppleIdentity>>;
    try {
      identity = await verifyAppleIdentity(
        identityToken,
        await sha256(rawNonce),
        clientIds,
        fullName,
      );
    } catch (error) {
      console.error(JSON.stringify({
        event: "apple_identity_verification_failed",
        requestId,
        error: error instanceof Error ? error.message : "unknown",
      }));
      return json({ error: "apple_identity_verification_failed", requestId }, 401);
    }
    const expectedUserId = await authenticatedUserId(request, watcher);
    let refreshToken: string | null;
    try {
      refreshToken = await exchangeAppleAuthorizationCode(
        configuration,
        identity.clientId,
        authorizationCode,
      );
    } catch (error) {
      console.error(JSON.stringify({
        event: "apple_code_exchange_failed",
        requestId,
        clientId: identity.clientId,
        error: error instanceof Error ? error.message : "unknown",
      }));
      return json({ error: "apple_code_exchange_failed", requestId }, 502);
    }
    const userId = await watcher.resolveAuthIdentity(identity, expectedUserId, refreshToken);
    if (userId === null) return json({ error: "account_identity_conflict" }, 409);
    const session = randomToken(48);
    const user = await watcher.createAuthSession(
      userId,
      await sha256(session),
      Date.now() + sessionLifetime,
    );
    return json({ token: session, user });
  }

  if (path.startsWith("/v1/auth/")) {
    const token = bearerToken(request);
    const userId = token === null ? null : await watcher.authUserIdForSession(await sha256(token));
    if (token === null || userId === null) return json({ error: "unauthorized" }, 401);
    if (request.method === "GET" && path === "/v1/auth/me") {
      return json({ user: await watcher.authUserForSession(await sha256(token)) });
    }
    if (request.method === "POST" && path === "/v1/auth/logout") {
      await watcher.revokeAuthSession(await sha256(token));
      return new Response(null, { status: 204 });
    }
    if (request.method === "DELETE" && path === "/v1/auth/account") {
      const configuration = appleConfiguration(env);
      const credentials = await watcher.appleRefreshCredentials(userId);
      if (credentials.length > 0 && configuration === null) {
        return json({ error: "apple_revocation_unavailable" }, 503);
      }
      for (const credential of credentials) {
        await revokeAppleRefreshToken(configuration!, credential.clientId, credential.refreshToken);
      }
      await watcher.deleteAuthUser(userId);
      return new Response(null, { status: 204 });
    }
  }

  return null;
}
