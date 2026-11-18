import { createHmac } from "node:crypto";
import Fastify, { type FastifyInstance, type FastifyReply } from "fastify";
import { z } from "zod";
import { RequestValidationError } from "../cloudflare/api-validation.js";
import { defaultPushPreferences } from "../domain/snapshot.js";
import { createSharedTripToken, resolveSharedTripToken } from "../domain/share-links.js";
import type { DeviceMutationOutcome, WatcherRepository } from "../db/repository.js";
import { deviceCredentialHash } from "../auth/device-credential.js";
import { coverageManifest } from "../cloudflare/coverage.js";
import {
  JourneyServiceUnavailableError,
  parseJourneyPlaceSearch,
  parseJourneyResolution,
  parseJourneySearch,
} from "../cloudflare/journey-validation.js";
import type { ProviderRegistry } from "../providers/provider.js";
import { isRailProviderUnavailable, providerRetryAfter } from "../providers/rail-provider-error.js";
import { JourneyProviderUnavailableError } from "../providers/journey-provider.js";
import { JourneyTrackingTokenExpiredError, type JourneySearchService } from "../services/journey-search-service.js";
import { JourneyRateLimitError } from "../services/journey-rate-limiter.js";

const deviceSchema = z.object({
  installationId: z.uuid(),
  token: z.string().regex(/^[a-fA-F0-9]{64,200}$/),
  environment: z.enum(["sandbox", "production"]),
  platform: z.enum(["ios", "macos"]),
});

const preferencesSchema = z.object({
  delayThresholdMinutes: z.number().int().min(0).max(180).default(defaultPushPreferences.delayThresholdMinutes),
  platformChanges: z.boolean().default(defaultPushPreferences.platformChanges),
  cancellations: z.boolean().default(defaultPushPreferences.cancellations),
  disruptions: z.boolean().default(defaultPushPreferences.disruptions),
});

const tripSchema = z.object({
  id: z.string().min(1).max(500),
  source: z.enum(["amtraker", "transitous", "srbijavoz", "ekispert", "tdx", "chepe", "db", "sncf", "irail", "renfe"]),
  nativeId: z.string().min(1).max(500),
  serviceDate: z.iso.date(),
});

const snapshotSchema = tripSchema.extend({
  source: z.enum(["amtraker", "transitous", "srbijavoz", "ekispert", "tdx", "chepe"]),
});

const subscriptionSchema = z.object({
  installationId: z.uuid(),
  trip: tripSchema,
  boardingStationId: z.string().min(1).max(500),
  alightingStationId: z.string().min(1).max(500),
  watchFrom: z.iso.datetime({ offset: true }),
  preferences: preferencesSchema.default(defaultPushPreferences),
});

const deleteSchema = z.object({
  installationId: z.uuid(),
  tripId: z.string().min(1).max(500),
});

const searchSchema = z.object({
  scope: z.enum(["us", "international"]),
  query: z.string().trim().min(2).max(100),
});

const boardSchema = z.object({
  stationId: z.string().min(1).max(500),
  source: z.enum(["amtraker", "transitous", "srbijavoz", "ekispert", "tdx", "chepe"]),
  nativeId: z.string().min(1).max(500),
  at: z.iso.datetime({ offset: true }),
  direction: z.enum(["arrivals", "departures"]),
});

const sharedTripSchema = z.object({
  trip: snapshotSchema,
  boardingStationId: z.string().min(1).max(500).nullable().optional(),
  alightingStationId: z.string().min(1).max(500).nullable().optional(),
});

const journeyBodyLimit = 48 * 1_024;
const mutationBodyLimit = 16 * 1_024;
const jsonBodyLimit = 64 * 1_024;
const maximumShareTokenLength = 4_000;
type JourneyService = Pick<JourneySearchService, "searchPlaces" | "searchJourneys" | "resolvePlan">;

function hasName(error: unknown, name: string): boolean {
  return error instanceof Error && error.name === name;
}

function errorCode(error: unknown): string | null {
  if (typeof error !== "object" || error === null || !("code" in error)) return null;
  return typeof error.code === "string" ? error.code : null;
}

function retryAfterSeconds(error: unknown): number {
  if (typeof error !== "object" || error === null || !("retryAfterSeconds" in error)) return 60;
  return typeof error.retryAfterSeconds === "number" ? error.retryAfterSeconds : 60;
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

function journeyContext(
  requestIP: string,
  service: JourneyService | null,
  tokenSecret: string | null,
): { service: JourneyService; clientKey: string } {
  if (service === null || tokenSecret === null || tokenSecret.length < 32) {
    throw new JourneyServiceUnavailableError();
  }
  return {
    service,
    clientKey: createHmac("sha256", tokenSecret).update(requestIP).digest("hex"),
  };
}

// Same status mapping as the Worker's `mutationResponse`.
function sendMutationOutcome(reply: FastifyReply, outcome: DeviceMutationOutcome) {
  if (outcome === "allowed") return reply.code(204).send();
  reply.header("cache-control", "no-store");
  if (outcome === "unauthorized") return reply.code(401).send({ error: "unauthorized" });
  return reply.code(409).send({ error: outcome });
}

async function sendRailRead(reply: FastifyReply, work: () => Promise<unknown>) {
  try {
    return reply.send(await work());
  } catch (error) {
    if (!isRailProviderUnavailable(error)) throw error;
    return reply.header("retry-after", String(providerRetryAfter(error)))
      .header("cache-control", "no-store").code(503).send({ error: "provider_unavailable" });
  }
}

export function makeApp(
  repository: WatcherRepository,
  providers: ProviderRegistry,
  logLevel = "info",
  shareLinkSecret: string | null = null,
  journeyService: JourneyService | null = null,
  journeyTokenSecret: string | null = null,
): FastifyInstance {
  const app = Fastify({
    logger: { level: logLevel }, bodyLimit: jsonBodyLimit,
    // Signed share tokens exceed the router's 100-character parameter default.
    routerOptions: { maxParamLength: maximumShareTokenLength },
  });

  app.get("/health", async (_request, reply) => {
    await repository.health();
    return reply.send({ status: "ok" });
  });

  app.get("/v1/coverage", async (_request, reply) => reply.send(coverageManifest));

  app.post("/v1/shares", async (request, reply) => {
    if (shareLinkSecret === null) return reply.code(503).send({ error: "sharing_unavailable" });
    const parsed = sharedTripSchema.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: "invalid_request", details: parsed.error.issues });
    const input = {
      trip: parsed.data.trip,
      ...(parsed.data.boardingStationId === undefined ? {} : { boardingStationId: parsed.data.boardingStationId }),
      ...(parsed.data.alightingStationId === undefined ? {} : { alightingStationId: parsed.data.alightingStationId }),
    };
    const shared = createSharedTripToken(input, shareLinkSecret);
    return reply.code(201).send({
      url: `${request.protocol}://${request.hostname}/s/${shared.token}`,
      expiresAt: shared.payload.expiresAt,
    });
  });

  app.get("/v1/shares/:token", async (request, reply) => {
    if (shareLinkSecret === null) return reply.code(503).send({ error: "sharing_unavailable" });
    const parsed = z.object({ token: z.string().min(1).max(maximumShareTokenLength) }).safeParse(request.params);
    if (!parsed.success) return reply.code(400).send({ error: "invalid_request", details: parsed.error.issues });
    try {
      return reply.send(resolveSharedTripToken(parsed.data.token, shareLinkSecret));
    } catch {
      return reply.code(404).send({ error: "share_not_found" });
    }
  });

  app.get("/v1/stations/search", async (request, reply) => {
    const parsed = searchSchema.safeParse(request.query);
    if (!parsed.success) return reply.code(400).send({ error: "invalid_request", details: parsed.error.issues });
    return sendRailRead(reply, () => providers.searchStations(parsed.data.scope, parsed.data.query));
  });

  app.get("/v1/stations/board", async (request, reply) => {
    const parsed = boardSchema.safeParse(request.query);
    if (!parsed.success) return reply.code(400).send({ error: "invalid_request", details: parsed.error.issues });
    return sendRailRead(reply, () => providers.fetchBoard(parsed.data));
  });

  app.get("/v1/trips/snapshot", async (request, reply) => {
    const parsed = snapshotSchema.safeParse(request.query);
    if (!parsed.success) return reply.code(400).send({ error: "invalid_request", details: parsed.error.issues });
    return sendRailRead(reply, async () => {
      const snapshot = await providers.fetchTrip(parsed.data);
      await repository.recordPlatformObservations(snapshot, "snapshot");
      return repository.forecastPlatformSnapshot(snapshot, snapshot.fetchedAt);
    });
  });

  app.register(async (journeyRoutes) => {
    journeyRoutes.addHook("onSend", async (_request, reply, payload) => {
      reply.header("cache-control", "no-store");
      return payload;
    });
    journeyRoutes.setErrorHandler((error, _request, reply) => {
      if (errorCode(error) === "FST_ERR_CTP_BODY_TOO_LARGE") {
        return reply.code(413).send({ error: "request_too_large" });
      }
      if (errorCode(error) === "FST_ERR_CTP_INVALID_JSON_BODY"
        || errorCode(error) === "FST_ERR_CTP_INVALID_MEDIA_TYPE"
        || error instanceof RequestValidationError || invalidServiceInput(error)) {
        return reply.code(400).send({ error: "invalid_request" });
      }
      if (error instanceof JourneyTrackingTokenExpiredError
        || hasName(error, "JourneyTrackingTokenExpiredError")) {
        return reply.code(409).send({ error: "tracking_token_expired" });
      }
      if (error instanceof JourneyRateLimitError || hasName(error, "JourneyRateLimitError")) {
        return reply.header("retry-after", String(retryAfterSeconds(error))).code(429).send({ error: "rate_limited" });
      }
      if (error instanceof JourneyServiceUnavailableError
        || hasName(error, "JourneyServiceUnavailableError")) {
        return reply.code(503).send({ error: "service_unavailable" });
      }
      if (error instanceof JourneyProviderUnavailableError
        || hasName(error, "JourneyProviderUnavailableError")) {
        return reply.code(503).send({ error: "service_unavailable" });
      }
      return reply.code(500).send({ error: "internal_error" });
    });

    journeyRoutes.get("/v1/places/search", { logLevel: "silent" }, async (request, reply) => {
      const journey = journeyContext(request.ip, journeyService, journeyTokenSecret);
      const url = new URL(request.raw.url ?? "", "http://localhost");
      const input = parseJourneyPlaceSearch(url.searchParams);
      return reply.send(await journey.service.searchPlaces(input.query, input.limit, journey.clientKey));
    });

    journeyRoutes.post("/v1/journeys/search", {
      bodyLimit: journeyBodyLimit,
      logLevel: "silent",
    }, async (request, reply) => {
      const journey = journeyContext(request.ip, journeyService, journeyTokenSecret);
      return reply.send(await journey.service.searchJourneys(parseJourneySearch(request.body), journey.clientKey));
    });

    journeyRoutes.post("/v1/journey-plans/resolve", {
      bodyLimit: journeyBodyLimit,
      logLevel: "silent",
    }, async (request, reply) => {
      const journey = journeyContext(request.ip, journeyService, journeyTokenSecret);
      return reply.send(await journey.service.resolvePlan(parseJourneyResolution(request.body), journey.clientKey));
    });
  });

  // Notification mutations require the same `Device <credential>` possession
  // proof as the Worker; only its SHA-256 is stored.
  app.post("/v1/devices", { bodyLimit: mutationBodyLimit }, async (request, reply) => {
    const credentialHash = deviceCredentialHash(request.headers.authorization);
    if (credentialHash === null) return reply.code(401).send({ error: "unauthorized" });
    const parsed = deviceSchema.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: "invalid_request", details: parsed.error.issues });
    return sendMutationOutcome(reply, await repository.registerDevice(parsed.data, credentialHash));
  });

  app.post("/v1/subscriptions", { bodyLimit: mutationBodyLimit }, async (request, reply) => {
    const credentialHash = deviceCredentialHash(request.headers.authorization);
    if (credentialHash === null) return reply.code(401).send({ error: "unauthorized" });
    const parsed = subscriptionSchema.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: "invalid_request", details: parsed.error.issues });
    return sendMutationOutcome(reply, await repository.subscribe(parsed.data, credentialHash));
  });

  app.delete("/v1/subscriptions", async (request, reply) => {
    const credentialHash = deviceCredentialHash(request.headers.authorization);
    if (credentialHash === null) return reply.code(401).send({ error: "unauthorized" });
    const parsed = deleteSchema.safeParse(request.query);
    if (!parsed.success) return reply.code(400).send({ error: "invalid_request", details: parsed.error.issues });
    return sendMutationOutcome(
      reply,
      await repository.unsubscribe(parsed.data.installationId, parsed.data.tripId, credentialHash),
    );
  });

  return app;
}
