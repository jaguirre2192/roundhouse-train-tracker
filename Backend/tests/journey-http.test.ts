import { createHmac } from "node:crypto";
import { afterEach, describe, expect, it } from "vitest";
import { makeApp } from "../src/http/app.js";
import { WatcherRepository } from "../src/db/repository.js";
import { createJourneyTrackingToken } from "../src/domain/journey-tokens.js";
import type { JourneySearchRequest } from "../src/domain/journey.js";
import { ProviderRegistry } from "../src/providers/provider.js";
import { JourneyProviderUnavailableError } from "../src/providers/journey-provider.js";
import {
  amsterdam,
  criteria,
  option,
  paris,
  reference,
  serviceFixture,
  startMilliseconds,
  tokenSecret,
} from "./helpers/journey-search-service-fixtures.js";

const apps: ReturnType<typeof makeApp>[] = [];
type LocalJourneyService = NonNullable<Parameters<typeof makeApp>[4]>;

function appFor(
  journeyService: LocalJourneyService | null,
  journeyTokenSecret: string | null = tokenSecret,
) {
  const app = makeApp(
    new WatcherRepository({} as ConstructorParameters<typeof WatcherRepository>[0]),
    new ProviderRegistry([]),
    "silent",
    null,
    journeyService,
    journeyTokenSecret,
  );
  apps.push(app);
  return app;
}

async function post(
  app: ReturnType<typeof makeApp>,
  path: string,
  body: unknown,
  remoteAddress = "198.51.100.24",
) {
  return app.inject({
    method: "POST",
    path,
    headers: { "content-type": "application/json" },
    payload: JSON.stringify(body),
    remoteAddress,
  });
}

afterEach(async () => {
  await Promise.all(apps.splice(0).map((app) => app.close()));
});

describe("local Fastify journey contract", () => {
  it("returns the Worker success shapes for place search, journey search, and plan resolution", async () => {
    const fixture = serviceFixture();
    const app = appFor(fixture.service);
    const remoteAddress = "203.0.113.42";
    const rawQuery = "Private Paris Query";

    const places = await app.inject({
      method: "GET",
      path: `/v1/places/search?q=${encodeURIComponent(rawQuery)}&scope=mainline&limit=20`,
      remoteAddress,
    });
    expect(places.statusCode).toBe(200);
    expect(places.headers["cache-control"]).toBe("no-store");
    expect(places.json()).toEqual([paris]);

    const searched = await post(app, "/v1/journeys/search", criteria(), remoteAddress);
    expect(searched.statusCode).toBe(200);
    expect(searched.headers["cache-control"]).toBe("no-store");
    expect(searched.json()).toMatchObject({
      generatedAt: "2026-07-21T19:00:00.000Z",
      expiresAt: expect.any(String),
      options: [{
        trackingToken: expect.any(String),
        segments: [{ kind: "rail" }],
      }],
      previousCursor: expect.any(String),
      nextCursor: expect.any(String),
      warnings: [],
      attributions: ["Transitous", "OpenStreetMap contributors"],
    });

    const trackingToken = searched.json().options[0].trackingToken as string;
    const resolved = await post(app, "/v1/journey-plans/resolve", { trackingTokens: [trackingToken] }, remoteAddress);
    expect(resolved.statusCode).toBe(200);
    expect(resolved.headers["cache-control"]).toBe("no-store");
    expect(resolved.json()).toMatchObject({ directions: [{
      originStationId: paris.id,
      destinationStationId: amsterdam.id,
      segments: [{ trip: { source: "transitous", nativeId: "search-trip" }, failure: null }],
    }] });

    expect(fixture.logger.metrics).toEqual([
      {
        operation: "places", provider: "transitous", originCountryCode: null,
        destinationCountryCode: null, latencyMilliseconds: 0, cacheHit: false,
        outcome: "success", optionCount: 1, errorClass: null, zeroResults: false,
      },
      {
        operation: "search", provider: "transitous", originCountryCode: "FR",
        destinationCountryCode: "NL", latencyMilliseconds: 0, cacheHit: false,
        outcome: "success", optionCount: 1, errorClass: null, zeroResults: false,
      },
      {
        operation: "resolve", provider: "transitous", originCountryCode: "FR",
        destinationCountryCode: "NL", latencyMilliseconds: 0, cacheHit: false,
        outcome: "success", optionCount: null, errorClass: null, zeroResults: false,
      },
    ]);
    const serializedMetrics = JSON.stringify(fixture.logger.metrics);
    const clientPseudonym = createHmac("sha256", tokenSecret).update(remoteAddress).digest("hex");
    for (const sensitive of [
      rawQuery,
      remoteAddress,
      clientPseudonym,
      paris.id,
      amsterdam.id,
      "provider-previous",
      "provider-next",
      trackingToken,
    ]) expect(serializedMetrics).not.toContain(sensitive);
  });

  it("derives a stable HMAC client key from the request IP and journey secret", async () => {
    const clientKeys: string[] = [];
    const service: LocalJourneyService = {
      async searchPlaces(_query: string, _limit: number, clientKey: string) {
        clientKeys.push(clientKey);
        return [];
      },
      async searchJourneys(_input: JourneySearchRequest, _clientKey: string) {
        throw new Error("unexpected searchJourneys call");
      },
      async resolvePlan(_tokens: string[], _clientKey: string) {
        throw new Error("unexpected resolvePlan call");
      },
    };
    const app = appFor(service);
    const remoteAddress = "192.0.2.77";

    for (let index = 0; index < 2; index += 1) {
      const response = await app.inject({
        method: "GET",
        path: "/v1/places/search?q=Paris&scope=mainline&limit=20",
        remoteAddress,
      });
      expect(response.statusCode).toBe(200);
    }

    const expected = createHmac("sha256", tokenSecret).update(remoteAddress).digest("hex");
    expect(clientKeys).toEqual([expected, expected]);
    expect(clientKeys).not.toContain(remoteAddress);
  });

  it("returns fixed bounded validation and body-limit errors without changing unrelated routes", async () => {
    const fixture = serviceFixture();
    const app = appFor(fixture.service);

    const invalidPlace = await app.inject({
      method: "GET",
      path: "/v1/places/search?q=x&scope=mainline&limit=20",
    });
    expect(invalidPlace.statusCode).toBe(400);
    expect(invalidPlace.headers["cache-control"]).toBe("no-store");
    expect(invalidPlace.payload).toBe('{"error":"invalid_request"}');

    const invalidJourney = await post(app, "/v1/journeys/search", { ...criteria(), extra: "private-value" });
    expect(invalidJourney.statusCode).toBe(400);
    expect(invalidJourney.payload).toBe('{"error":"invalid_request"}');
    expect(invalidJourney.payload).not.toContain("private-value");

    const malformed = await app.inject({
      method: "POST",
      path: "/v1/journeys/search",
      headers: { "content-type": "application/json" },
      payload: "{private malformed json",
    });
    expect(malformed.statusCode).toBe(400);
    expect(malformed.payload).toBe('{"error":"invalid_request"}');

    const oversized = await post(app, "/v1/journeys/search", { padding: "private-body".repeat(5_000) });
    expect(oversized.statusCode).toBe(413);
    expect(oversized.headers["cache-control"]).toBe("no-store");
    expect(oversized.payload).toBe('{"error":"request_too_large"}');
    expect(oversized.payload).not.toContain("private-body");

    const unrelated = await app.inject({
      method: "POST",
      path: "/v1/devices",
      payload: {},
      headers: { authorization: `Device ${"d".repeat(43)}` },
    });
    expect(unrelated.statusCode).toBe(400);
    expect(unrelated.headers["cache-control"]).toBeUndefined();
    expect(unrelated.json()).toHaveProperty("details");
  });

  it.each([
    ["missing", undefined],
    ["unsupported", { "content-type": "application/x-private-journey" }],
  ] as const)("normalizes %s journey content type to a fixed invalid request", async (_case, headers) => {
    const fixture = serviceFixture();
    const app = appFor(fixture.service);
    const privateBody = '{"private":"journey-body"}';

    const response = await app.inject({
      method: "POST",
      path: "/v1/journeys/search",
      ...(headers === undefined ? {} : { headers }),
      payload: privateBody,
    });
    expect(response.statusCode).toBe(400);
    expect(response.headers["cache-control"]).toBe("no-store");
    expect(response.payload).toBe('{"error":"invalid_request"}');
    expect(response.payload).not.toContain(privateBody);
    expect(response.payload).not.toContain("application/x-private-journey");
  });

  it("returns service unavailable for missing or short journey secrets", async () => {
    const fixture = serviceFixture();
    for (const [service, secret] of [
      [null, null],
      [null, "x".repeat(31)],
      [fixture.service, "x".repeat(31)],
    ] as const) {
      const response = await appFor(service, secret).inject({
        method: "GET",
        path: "/v1/places/search?q=Paris&scope=mainline&limit=20",
      });
      expect(response.statusCode).toBe(503);
      expect(response.headers["cache-control"]).toBe("no-store");
      expect(response.payload).toBe('{"error":"service_unavailable"}');
    }
  });

  it("maps only explicit journey-provider failures to service unavailable", async () => {
    const unavailableService: LocalJourneyService = {
      async searchPlaces() {
        throw new JourneyProviderUnavailableError("private upstream place failure");
      },
      async searchJourneys() {
        throw new JourneyProviderUnavailableError("private upstream plan failure");
      },
      async resolvePlan() {
        throw new JourneyProviderUnavailableError("private upstream resolution failure");
      },
    };
    const unavailableApp = appFor(unavailableService);
    const placeResponse = await unavailableApp.inject({
      method: "GET",
      path: "/v1/places/search?q=ProviderFailure&scope=mainline&limit=20",
    });
    const searchResponse = await post(unavailableApp, "/v1/journeys/search", criteria());

    for (const response of [placeResponse, searchResponse]) {
      expect(response.statusCode).toBe(503);
      expect(response.headers["cache-control"]).toBe("no-store");
      expect(response.payload).toBe('{"error":"service_unavailable"}');
      expect(response.payload).not.toContain("private upstream");
    }

    const internalService: LocalJourneyService = {
      ...unavailableService,
      async searchPlaces() {
        throw new Error("private programming failure");
      },
    };
    const internalResponse = await appFor(internalService).inject({
      method: "GET",
      path: "/v1/places/search?q=InternalFailure&scope=mainline&limit=20",
    });
    expect(internalResponse.statusCode).toBe(500);
    expect(internalResponse.payload).toBe('{"error":"internal_error"}');
    expect(internalResponse.payload).not.toContain("private programming failure");
  });

  it("maps expired tracking tokens and rate limits to the Worker error contract", async () => {
    const expiryFixture = serviceFixture();
    const expiryApp = appFor(expiryFixture.service);
    const expired = createJourneyTrackingToken(
      option("expired", [{ segmentId: "expired-segment", reference: reference("transitous", "expired-trip") }]),
      tokenSecret,
      new Date(startMilliseconds - 11 * 60_000),
    ).token;
    const expiredResponse = await post(expiryApp, "/v1/journey-plans/resolve", { trackingTokens: [expired] });
    expect(expiredResponse.statusCode).toBe(409);
    expect(expiredResponse.payload).toBe('{"error":"tracking_token_expired"}');

    const rateFixture = serviceFixture();
    const rateApp = appFor(rateFixture.service);
    for (let index = 0; index < 30; index += 1) {
      const allowed = await rateApp.inject({
        method: "GET",
        path: "/v1/places/search?q=RateLimitUnique&scope=mainline&limit=1",
        remoteAddress: "198.51.100.77",
      });
      expect(allowed.statusCode).toBe(200);
    }
    const limited = await rateApp.inject({
      method: "GET",
      path: "/v1/places/search?q=RateLimitUnique&scope=mainline&limit=1",
      remoteAddress: "198.51.100.77",
    });
    expect(limited.statusCode).toBe(429);
    expect(limited.headers["cache-control"]).toBe("no-store");
    expect(limited.headers["retry-after"]).toBe("60");
    expect(limited.payload).toBe('{"error":"rate_limited"}');
  });
});
