import { createHash, createHmac } from "node:crypto";
import type { WorkerEnv } from "./env.js";
import { deviceCredentialHash } from "../auth/device-credential.js";

export type MutationOperation = "register_device" | "subscribe" | "unsubscribe" | "register_live_activity" | "stop_live_activity";

export type MutationDecision =
  | { allowed: true }
  | {
    allowed: false;
    reason: "unauthorized" | "rate_limited" | "quota_exceeded" | "token_conflict" | "trip_conflict";
    retryAfterSeconds?: number;
  };

export interface MutationContext {
  credentialHash: string;
  clientKey: string;
}

export class MutationServiceUnavailableError extends Error {
  constructor() {
    super("Notification mutations are unavailable");
    this.name = "MutationServiceUnavailableError";
  }
}

export class MutationUnauthorizedError extends Error {
  constructor() {
    super("A device credential is required");
    this.name = "MutationUnauthorizedError";
  }
}

export function mutationContext(request: Request, env: WorkerEnv): MutationContext {
  const credentialHash = deviceCredentialHash(request.headers.get("authorization"));
  if (credentialHash === null) throw new MutationUnauthorizedError();

  const secret = env.JOURNEY_TOKEN_SECRET;
  if (secret === undefined || secret.length < 32) throw new MutationServiceUnavailableError();
  const address = clientAddress(request);
  if (address === null) throw new MutationServiceUnavailableError();

  return {
    credentialHash,
    clientKey: createHmac("sha256", secret).update(address).digest("hex"),
  };
}

/// Opaque per-network key for public reads. Unlike mutations, reads stay
/// available without the journey secret, falling back to an unkeyed digest.
export function publicReadClientKey(request: Request, env: WorkerEnv): string {
  const address = clientAddress(request) ?? "unknown";
  const secret = env.JOURNEY_TOKEN_SECRET;
  return secret !== undefined && secret.length >= 32
    ? createHmac("sha256", secret).update(address).digest("hex")
    : createHash("sha256").update(`public-read:${address}`).digest("hex");
}

function clientAddress(request: Request): string | null {
  const forwarded = request.headers.get("CF-Connecting-IP")?.trim();
  if (forwarded !== undefined && forwarded.length > 0) return forwarded;
  const hostname = new URL(request.url).hostname;
  return hostname === "localhost" || hostname === "127.0.0.1"
      || hostname === "::1" || hostname.endsWith(".test")
    ? "unknown"
    : null;
}

export function mutationResponse(
  operation: MutationOperation,
  decision: MutationDecision,
): Response {
  const outcome = decision.allowed ? "allowed" : decision.reason;
  console.info("mutation_metric", { operation, outcome });
  if (decision.allowed) return new Response(null, { status: 204 });
  if (decision.reason === "rate_limited") {
    const retryAfter = decision.retryAfterSeconds ?? 60;
    return Response.json(
      { error: "rate_limited" },
      { status: 429, headers: { "cache-control": "no-store", "retry-after": String(retryAfter) } },
    );
  }
  const status = decision.reason === "unauthorized" ? 401 : 409;
  const error = decision.reason === "unauthorized" ? "unauthorized" : decision.reason;
  return Response.json({ error }, { status, headers: { "cache-control": "no-store" } });
}
