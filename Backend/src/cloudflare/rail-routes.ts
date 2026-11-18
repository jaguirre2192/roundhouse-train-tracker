import type { TrainTrackerWatcher } from "./watcher-object.js";
import type { WorkerEnv } from "./env.js";
import {
  parseDeviceRegistration,
  parseStationBoardRequest,
  parseStationSearchRequest,
  parseSubscription,
  parseTripSnapshotRequest,
  parseUnsubscribe,
} from "./api-validation.js";
import { boundedJSONBody, json } from "./http.js";
import { mutationContext, mutationResponse, publicReadClientKey } from "./mutation-security.js";
import { isRailProviderUnavailable, providerRetryAfter } from "../providers/rail-provider-error.js";

const mutationBodyLimit = 16 * 1_024;

function rateLimitedResponse(error: unknown): Response | null {
  if (!(error instanceof Error) || error.name !== "RateLimitExceededError") return null;
  const retryAfter = "retryAfterSeconds" in error && typeof error.retryAfterSeconds === "number"
    ? error.retryAfterSeconds
    : 60;
  return json({ error: "rate_limited" }, 429, { "retry-after": String(retryAfter) });
}

async function publicRead(work: () => Promise<unknown>): Promise<Response> {
  try {
    return json(await work());
  } catch (error) {
    const limited = rateLimitedResponse(error);
    if (limited !== null) return limited;
    if (isRailProviderUnavailable(error)) {
      return json({ error: "provider_unavailable" }, 503, {
        "retry-after": String(providerRetryAfter(error)), "cache-control": "no-store",
      });
    }
    throw error;
  }
}

export async function handleRailRequest(
  request: Request,
  env: WorkerEnv,
  watcher: DurableObjectStub<TrainTrackerWatcher>,
  url: URL,
  path: string,
): Promise<Response | null> {
  // Counts and freshness only; no tokens, credentials, or rider identifiers.
  if (request.method === "GET" && path === "/health") {
    return json({ service: "train-tracker-api", ...await watcher.health() });
  }
  if (request.method === "GET" && path === "/v1/stations/search") {
    const input = parseStationSearchRequest(url.searchParams);
    const clientKey = publicReadClientKey(request, env);
    return publicRead(() => watcher.searchStations(input.scope, input.query, clientKey));
  }
  if (request.method === "GET" && path === "/v1/stations/board") {
    const input = parseStationBoardRequest(url.searchParams);
    const clientKey = publicReadClientKey(request, env);
    return publicRead(() => watcher.board(input, clientKey));
  }
  if (request.method === "POST" && path === "/v1/devices") {
    const context = mutationContext(request, env);
    const input = parseDeviceRegistration(await boundedJSONBody(request, mutationBodyLimit));
    return mutationResponse("register_device", await watcher.registerDevice(input, context));
  }
  if (request.method === "POST" && path === "/v1/subscriptions") {
    const context = mutationContext(request, env);
    const input = parseSubscription(await boundedJSONBody(request, mutationBodyLimit));
    return mutationResponse("subscribe", await watcher.subscribe(input, context));
  }
  if (request.method === "GET" && path === "/v1/trips/snapshot") {
    const input = parseTripSnapshotRequest(url.searchParams);
    const clientKey = publicReadClientKey(request, env);
    return publicRead(() => watcher.snapshot(input, clientKey));
  }
  if (request.method === "DELETE" && path === "/v1/subscriptions") {
    const context = mutationContext(request, env);
    const input = parseUnsubscribe(url.searchParams);
    return mutationResponse(
      "unsubscribe",
      await watcher.unsubscribe(input.installationId, input.tripId, context),
    );
  }
  return null;
}
