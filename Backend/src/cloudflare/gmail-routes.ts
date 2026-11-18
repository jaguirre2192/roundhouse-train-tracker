import type { TrainTrackerWatcher } from "./watcher-object.js";
import type { WorkerEnv } from "./env.js";
import { authenticatedUserId } from "./request-session.js";
import { GmailAPI } from "../gmail/gmail-api.js";
import { encryptSecret, randomToken, sha256 } from "../gmail/gmail-crypto.js";
import { exchangeGmailCode, gmailAuthorizationURL } from "../gmail/gmail-oauth.js";
import { gmailConnectedPage } from "./public-pages.js";
import { json, requestBody } from "./http.js";

function configuration(env: WorkerEnv, origin: string) {
  if (env.GMAIL_OAUTH_CLIENT_ID === undefined || env.GMAIL_OAUTH_CLIENT_SECRET === undefined
    || env.GMAIL_TOKEN_ENCRYPTION_KEY === undefined) return null;
  return {
    clientId: env.GMAIL_OAUTH_CLIENT_ID,
    clientSecret: env.GMAIL_OAUTH_CLIENT_SECRET,
    redirectURI: `${origin}/v1/gmail/oauth/callback`,
  };
}

function bodyCode(value: unknown): string | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const code = (value as Record<string, unknown>).code;
  return typeof code === "string" && code.length >= 20 && code.length <= 500 ? code : null;
}

function handoffInput(value: unknown): { transactionId: string; challenge: string } | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  if (typeof record.transactionId !== "string" || record.transactionId.length < 16
    || record.transactionId.length > 200 || typeof record.challenge !== "string"
    || record.challenge.length < 43 || record.challenge.length > 100) return null;
  return { transactionId: record.transactionId, challenge: record.challenge };
}

function handoffExchangeInput(value: unknown): {
  code: string;
  transactionId: string;
  verifier: string;
} | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  const code = bodyCode(value);
  if (code === null || typeof record.transactionId !== "string" || record.transactionId.length < 16
    || record.transactionId.length > 200 || typeof record.verifier !== "string" || record.verifier.length < 32
    || record.verifier.length > 500) return null;
  return { code, transactionId: record.transactionId, verifier: record.verifier };
}

function decodeBase64URL(value: string): Uint8Array {
  const normalized = value.replace(/-/gu, "+").replace(/_/gu, "/");
  const binary = atob(normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "="));
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

// Gmail ticket import is retired (the app ships it disabled in every build). Every
// Gmail API path and the OAuth landing page answer 410 so the account-linking flow,
// webhook, scans, and stored-ticket reads cannot run.
export function retiredGmailResponse(path: string): Response | null {
  if (path !== "/gmail-connected" && path !== "/v1/gmail" && !path.startsWith("/v1/gmail/")) return null;
  return json({ error: "gmail_import_retired" }, 410);
}

export function handleGmailLandingRequest(url: URL, path: string): Response | null {
  if (path !== "/gmail-connected") return null;
  const code = url.searchParams.get("code");
  const transactionId = url.searchParams.get("transaction");
  if (code === null || code.length < 20 || code.length > 500 || transactionId === null
    || transactionId.length < 16 || transactionId.length > 200) {
    return json({ error: "invalid_exchange_code" }, 400);
  }
  return gmailConnectedPage(code, transactionId);
}

export async function handleGmailAPIRequest(
  request: Request,
  env: WorkerEnv,
  ctx: ExecutionContext,
  watcher: DurableObjectStub<TrainTrackerWatcher>,
  url: URL,
  path: string,
): Promise<Response | null> {
  if (request.method === "GET" && path === "/v1/gmail/status") {
    return json({ available: await watcher.gmailAvailable() });
  }

  if (request.method === "POST" && path === "/v1/gmail/oauth/start") {
    const gmail = configuration(env, url.origin);
    if (gmail === null || !await watcher.gmailAvailable()) {
      return json({ error: "gmail_import_unavailable" }, 503);
    }
    const linkUserId = await authenticatedUserId(request, watcher);
    if (linkUserId === null) return json({ error: "unauthorized" }, 401);
    const handoff = handoffInput(await requestBody(request));
    if (handoff === null) return json({ error: "invalid_request" }, 400);
    const state = randomToken();
    const verifier = randomToken(48);
    const accepted = await watcher.createGmailOAuthState(
      await sha256(state),
      verifier,
      linkUserId,
      handoff.transactionId,
      handoff.challenge,
      Date.now() + 10 * 60_000,
    );
    if (!accepted) {
      return new Response(JSON.stringify({ error: "too_many_pending_connections" }), {
        status: 429,
        headers: { "content-type": "application/json", "retry-after": "600", "cache-control": "no-store" },
      });
    }
    return json({ url: gmailAuthorizationURL(gmail, state, await sha256(verifier)).toString() });
  }

  if (request.method === "GET" && path === "/v1/gmail/oauth/callback") {
    const gmail = configuration(env, url.origin);
    if (gmail === null) return json({ error: "gmail_import_unavailable" }, 503);
    const state = url.searchParams.get("state");
    const code = url.searchParams.get("code");
    if (state === null || code === null) return json({ error: "invalid_oauth_callback" }, 400);
    const pending = await watcher.consumeGmailOAuthState(await sha256(state));
    if (pending === null) return json({ error: "oauth_state_expired" }, 400);
    const token = await exchangeGmailCode(gmail, code, pending.verifier);
    const api = new GmailAPI(token.access_token);
    const profile = await api.profile();
    let userId: string;
    if (token.refresh_token !== undefined) {
      const encrypted = await encryptSecret(token.refresh_token, env.GMAIL_TOKEN_ENCRYPTION_KEY ?? "");
      const connected = await watcher.connectGmailAccount(
        pending.linkUserId,
        profile.emailAddress,
        encrypted,
        profile.historyId,
      );
      if (connected.status === "owner_conflict") return json({ error: "gmail_account_already_connected" }, 409);
      if (connected.status === "account_limit") return json({ error: "gmail_account_limit" }, 409);
      userId = connected.userId;
    } else {
      const existingUserId = await watcher.gmailUserForEmail(profile.emailAddress);
      if (existingUserId === null) return json({ error: "gmail_refresh_token_missing" }, 400);
      if (pending.linkUserId !== existingUserId) {
        return json({ error: "gmail_account_already_connected" }, 409);
      }
      userId = existingUserId;
    }
    const exchangeCode = randomToken();
    await watcher.createGmailExchangeCode(
      await sha256(exchangeCode),
      userId,
      pending.transactionId,
      pending.appChallenge,
      Date.now() + 5 * 60_000,
    );
    ctx.waitUntil(watcher.scanGmailUser(userId));
    return new Response(null, {
      status: 303,
      headers: {
        location: `${url.origin}/gmail-connected?code=${encodeURIComponent(exchangeCode)}&transaction=${encodeURIComponent(pending.transactionId)}`,
        "cache-control": "no-store",
      },
    });
  }

  if (request.method === "POST" && path === "/v1/gmail/session/exchange") {
    const userId = await authenticatedUserId(request, watcher);
    if (userId === null) return json({ error: "unauthorized" }, 401);
    const handoff = handoffExchangeInput(await requestBody(request));
    if (handoff === null) return json({ error: "invalid_exchange" }, 400);
    const accepted = await watcher.completeGmailConnection(
      await sha256(handoff.code),
      handoff.transactionId,
      await sha256(handoff.verifier),
      userId,
    );
    return accepted ? json({ connected: true }) : json({ error: "exchange_code_expired" }, 400);
  }

  if (request.method === "POST" && path === "/v1/gmail/webhook") {
    if (env.GMAIL_WEBHOOK_TOKEN === undefined || url.searchParams.get("token") !== env.GMAIL_WEBHOOK_TOKEN) {
      return json({ error: "unauthorized" }, 401);
    }
    const input = await requestBody(request) as { message?: { data?: string } };
    const encoded = input.message?.data;
    if (encoded === undefined) return json({ error: "invalid_notification" }, 400);
    const notice = JSON.parse(new TextDecoder().decode(decodeBase64URL(encoded))) as { emailAddress?: string };
    if (notice.emailAddress === undefined) return json({ error: "invalid_notification" }, 400);
    ctx.waitUntil(watcher.scanGmailEmail(notice.emailAddress));
    return new Response(null, { status: 204 });
  }

  if (!path.startsWith("/v1/gmail/")) return null;
  const userId = await authenticatedUserId(request, watcher);
  if (userId === null) return json({ error: "unauthorized" }, 401);
  if (request.method === "GET" && path === "/v1/gmail/connections") {
    return json(await watcher.gmailConnections(userId));
  }
  if (request.method === "GET" && path === "/v1/gmail/tickets") {
    return json(await watcher.gmailTickets(userId));
  }
  if (request.method === "POST" && path === "/v1/gmail/scan") {
    const result = await watcher.scanGmailUserManual(userId);
    if (result.status === "cooldown") {
      return new Response(JSON.stringify({ error: "scan_cooldown", retryAfter: result.retryAfter }), {
        status: 429,
        headers: {
          "content-type": "application/json",
          "cache-control": "no-store",
          "retry-after": String(result.retryAfter),
        },
      });
    }
    return json({ imported: result.imported });
  }
  const artifactMatch = path.match(/^\/v1\/gmail\/tickets\/(.+)\/artifact$/u);
  if (request.method === "GET" && artifactMatch?.[1] !== undefined) {
    const artifact = await watcher.gmailArtifact(userId, decodeURIComponent(artifactMatch[1]));
    if (artifact === null) return json({ error: "artifact_not_found" }, 404);
    const bytes = decodeBase64URL(artifact.data);
    const body = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
    return new Response(body, {
      headers: {
        "content-type": artifact.mimeType,
        "content-disposition": `inline; filename="${artifact.filename.replace(/["\\\r\n]/gu, "_")}"`,
        "cache-control": "private, no-store",
      },
    });
  }
  const connectionMatch = path.match(/^\/v1\/gmail\/connections\/([^/]+)$/u);
  if (request.method === "DELETE" && connectionMatch?.[1] !== undefined) {
    await watcher.disconnectGmailAccount(userId, decodeURIComponent(connectionMatch[1]));
    return new Response(null, { status: 204 });
  }
  return null;
}
