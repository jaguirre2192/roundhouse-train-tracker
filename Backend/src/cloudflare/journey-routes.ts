import { createHmac } from "node:crypto";
import { JourneyRateLimitError } from "../services/journey-rate-limiter.js";
import { JourneyTrackingTokenExpiredError } from "../services/journey-search-service.js";
import { JourneyProviderUnavailableError } from "../providers/journey-provider.js";
import type { TrainTrackerWatcher } from "./watcher-object.js";
import type { WorkerEnv } from "./env.js";
import { boundedJSONBody, json, RequestBodyTooLargeError } from "./http.js";
import { RequestValidationError } from "./api-validation.js";
import {
  JourneyServiceUnavailableError,
  parseJourneyPlaceSearch,
  parseJourneyResolution,
  parseJourneySearch,
} from "./journey-validation.js";

function secret(env: WorkerEnv): string {
  if (env.JOURNEY_TOKEN_SECRET === undefined || env.JOURNEY_TOKEN_SECRET.length < 32) {
    throw new JourneyServiceUnavailableError();
  }
  return env.JOURNEY_TOKEN_SECRET;
}

function clientKey(request: Request, env: WorkerEnv): string {
  const tokenSecret = secret(env);
  const header = request.headers.get("CF-Connecting-IP")?.trim();
  const hostname = new URL(request.url).hostname;
  const isLocalRequest = hostname === "localhost" || hostname === "127.0.0.1"
    || hostname === "::1" || hostname.endsWith(".test");
  const address = header === undefined || header.length === 0
    ? isLocalRequest ? "unknown" : null
    : header;
  if (address === null) throw new JourneyServiceUnavailableError();
  return createHmac("sha256", tokenSecret).update(address).digest("hex");
}

function invalidServiceInput(error: unknown): boolean {
  return error instanceof Error && [
    "Invalid journey cursor",
    "Journey cursor expired",
    "Invalid journey tracking token",
    "Invalid rail place ID",
    "Rail place is not eligible for journey planning",
  ].includes(error.message);
}

function errorResponse(error: unknown): Response | null {
  if (error instanceof RequestBodyTooLargeError) return json({ error: "request_too_large" }, 413);
  if (error instanceof RequestValidationError || invalidServiceInput(error)) {
    return json({ error: "invalid_request" }, 400);
  }
  if (error instanceof JourneyTrackingTokenExpiredError
    || (error instanceof Error && error.name === "JourneyTrackingTokenExpiredError")) {
    return json({ error: "tracking_token_expired" }, 409);
  }
  if (error instanceof JourneyRateLimitError
    || (error instanceof Error && error.name === "JourneyRateLimitError")) {
    const retryAfter = "retryAfterSeconds" in error && typeof error.retryAfterSeconds === "number"
      ? error.retryAfterSeconds
      : 60;
    return json({ error: "rate_limited" }, 429, { "retry-after": String(retryAfter) });
  }
  if (error instanceof JourneyServiceUnavailableError
    || (error instanceof Error && error.name === "JourneyServiceUnavailableError")) {
    return json({ error: "service_unavailable" }, 503);
  }
  if (error instanceof JourneyProviderUnavailableError
    || (error instanceof Error && error.name === "JourneyProviderUnavailableError")) {
    return json({ error: "service_unavailable" }, 503);
  }
  return null;
}

export async function handleJourneyRequest(
  request: Request,
  env: WorkerEnv,
  watcher: DurableObjectStub<TrainTrackerWatcher>,
  url: URL,
  path: string,
): Promise<Response | null> {
  const isPlaceSearch = request.method === "GET" && path === "/v1/places/search";
  const isJourneySearch = request.method === "POST" && path === "/v1/journeys/search";
  const isResolution = request.method === "POST" && path === "/v1/journey-plans/resolve";
  if (!isPlaceSearch && !isJourneySearch && !isResolution) return null;

  try {
    const key = clientKey(request, env);
    if (isPlaceSearch) {
      const input = parseJourneyPlaceSearch(url.searchParams);
      return json(await watcher.searchPlaces(input.query, input.limit, key));
    }
    if (isJourneySearch) {
      return json(await watcher.searchJourneys(parseJourneySearch(await boundedJSONBody(request)), key));
    }
    return json(await watcher.resolveJourneyPlan(parseJourneyResolution(await boundedJSONBody(request)), key));
  } catch (error) {
    const response = errorResponse(error);
    if (response !== null) return response;
    throw error;
  }
}
