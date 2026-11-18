import { syntheticChepePublication as chepePublication } from "../tests/fixtures/chepe-sample.js";
import { createExecutionContext, env, runDurableObjectAlarm, SELF } from "cloudflare:test";
import { createHmac } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
import { createJourneyTrackingToken } from "../src/domain/journey-tokens.js";
import type { JourneyOptionSnapshot, JourneySearchPageSnapshot } from "../src/domain/journey.js";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { encodeRailPlaceId } from "../src/providers/rail-place-id.js";
import worker from "../src/cloudflare/index.js";
import type { WorkerEnv } from "../src/cloudflare/env.js";

const journeySecret = "worker-test-journey-secret-32-characters";
const parisId = encodeRailPlaceId({
  provider: "transitous", kind: "station", nativeId: "fr-mainline_paris", countryCode: "FR",
  latitude: null, longitude: null,
});
const amsterdamId = encodeRailPlaceId({
  provider: "transitous", kind: "station", nativeId: "nl-mainline_amsterdam", countryCode: "NL",
  latitude: null, longitude: null,
});

function journeyLeg(
  tripId: string,
  from: { name: string; id: string; country: string; lat: number; lon: number },
  to: { name: string; id: string; country: string; lat: number; lon: number },
  startTime: string,
  endTime: string,
) {
  const place = (value: typeof from, time: string, position: "from" | "to") => ({
    name: value.name, stopId: value.id, lat: value.lat, lon: value.lon,
    tz: value.country === "FR" ? "Europe/Paris" : "Europe/Amsterdam",
    ...(position === "from"
      ? { departure: time, scheduledDeparture: time }
      : { arrival: time, scheduledArrival: time }),
  });
  return {
    mode: "LONG_DISTANCE", routeType: 102,
    from: place(from, startTime, "from"), to: place(to, endTime, "to"),
    startTime, endTime, scheduledStartTime: startTime, scheduledEndTime: endTime,
    duration: (Date.parse(endTime) - Date.parse(startTime)) / 1_000,
    realTime: false, cancelled: false, agencyName: "Test Rail", tripId,
    routeShortName: "IC", tripShortName: tripId.slice(-3), intermediateStops: [],
  };
}

const paris = { name: "Paris-Nord", id: "fr-mainline_paris", country: "FR", lat: 48.88, lon: 2.35 };
const brussels = { name: "Bruxelles-Midi", id: "be-mainline_brussels", country: "BE", lat: 50.84, lon: 4.34 };
const amsterdam = { name: "Amsterdam Centraal", id: "nl-mainline_amsterdam", country: "NL", lat: 52.38, lon: 4.90 };
const firstLeg = journeyLeg("20260724_fr-mainline_101", paris, brussels, "2026-07-24T06:25:00Z", "2026-07-24T07:47:00Z");
const secondLeg = journeyLeg("20260724_nl-mainline_202", brussels, amsterdam, "2026-07-24T08:22:00Z", "2026-07-24T10:14:00Z");
const journeyPlan = {
  previousPageCursor: "earlier-private-cursor", nextPageCursor: "later-private-cursor",
  itineraries: [{
    id: "private-provider-option", startTime: firstLeg.startTime, endTime: secondLeg.endTime,
    duration: 13_740, transfers: 1, legs: [firstLeg, secondLeg],
  }],
};

interface TransitousReply {
  path: (value: string) => boolean;
  value: unknown;
  status: number;
}

function interceptTransitous(replies: TransitousReply[], path: (value: string) => boolean, value: unknown, status = 200): void {
  replies.push({ path, value, status });
}

function mockTransitous(replies: TransitousReply[]) {
  return vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
    const url = new URL(typeof input === "string" || input instanceof URL ? input : input.url);
    const index = replies.findIndex((reply) => reply.path(`${url.pathname}${url.search}`));
    if (url.origin !== "https://api.transitous.org" || index < 0) throw new Error("Unexpected external request");
    const [reply] = replies.splice(index, 1);
    return Response.json(reply!.value, { status: reply!.status });
  });
}

const forbiddenJourneyKeys = new Set([
  "price", "currency", "seller", "checkouturl", "passenger", "passengers",
  "passengercount", "adultcount", "childcount", "childages", "railcard", "railcards",
]);

function recursivelyCollectForbiddenJourneyKeys(value: unknown, result: string[] = []): string[] {
  if (Array.isArray(value)) {
    for (const item of value) recursivelyCollectForbiddenJourneyKeys(item, result);
    return result;
  }
  if (typeof value !== "object" || value === null) return result;
  for (const [key, child] of Object.entries(value)) {
    if (forbiddenJourneyKeys.has(key.toLocaleLowerCase("en-US"))) result.push(key);
    recursivelyCollectForbiddenJourneyKeys(child, result);
  }
  return result;
}

const installationId = "ba141c63-e992-48ed-8c46-86cb6d42586a";
const deviceCredential = "d".repeat(43);
const device = {
  installationId,
  token: "a".repeat(64),
  environment: "sandbox",
  platform: "ios",
};
const subscription = {
  installationId,
  trip: {
    id: "us:amtraker:171-20",
    source: "amtraker",
    nativeId: "171-20",
    serviceDate: "2026-07-20",
  },
  boardingStationId: "us:amtraker:NYP",
  alightingStationId: "us:amtraker:PHL",
  watchFrom: "2099-07-20T18:00:00.000Z",
  preferences: {
    delayThresholdMinutes: 5,
    platformChanges: true,
    cancellations: true,
    disruptions: true,
  },
};

const dbPlatformSnapshot: TripSnapshot = {
  id: "eu:transitous:ice-742",
  source: "transitous",
  nativeId: "ice-742",
  serviceDate: "2026-07-21",
  operatorName: "DB Fernverkehr AG",
  product: "ICE 742",
  headsign: "Münster Hbf",
  fetchedAt: "2026-07-21T16:10:05.000Z",
  alertIds: [],
  stops: [{
    stationId: "eu:transitous:berlin-hbf",
    stationName: "Berlin Hbf",
    countryCode: "DE",
    latitude: 52.525,
    longitude: 13.369,
    sequence: 1,
    scheduledArrival: "2026-07-21T16:12:00.000Z",
    scheduledDeparture: "2026-07-21T16:16:00.000Z",
    expectedArrival: "2026-07-21T16:12:00.000Z",
    expectedDeparture: "2026-07-21T16:21:00.000Z",
    plannedPlatform: "8",
    expectedPlatform: "11",
    platformSource: "DB Timetables",
    platformObservedAt: "2026-07-21T16:10:00.000Z",
    cancelled: false,
    passed: false,
  }],
};

async function post(path: string, body: object): Promise<Response> {
  return SELF.fetch(`https://example.test${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function mutate(
  path: string,
  body: object,
  credential = deviceCredential,
  address = "198.51.100.10",
): Promise<Response> {
  return SELF.fetch(`https://example.test${path}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Device ${credential}`,
      "CF-Connecting-IP": address,
    },
    body: JSON.stringify(body),
  });
}

describe("Cloudflare API", () => {
  it("answers every retired Gmail route with 410 before any OAuth, scan, or ticket work", async () => {
    const requests: Array<[string, string]> = [
      ["GET", "/v1/gmail/status"],
      ["POST", "/v1/gmail/oauth/start"],
      ["GET", `/v1/gmail/oauth/callback?state=${"s".repeat(32)}&code=${"c".repeat(32)}`],
      ["POST", "/v1/gmail/session/exchange"],
      ["POST", "/v1/gmail/webhook?token=anything"],
      ["GET", "/v1/gmail/connections"],
      ["DELETE", "/v1/gmail/connections/abc"],
      ["GET", "/v1/gmail/tickets"],
      ["GET", "/v1/gmail/tickets/abc/artifact"],
      ["POST", "/v1/gmail/scan"],
      ["GET", "/v1/gmail"],
      ["GET", `/gmail-connected?code=${"a".repeat(32)}&transaction=${"b".repeat(32)}`],
    ];
    for (const [method, path] of requests) {
      const response = await SELF.fetch(`https://example.test${path}`, {
        method,
        headers: { authorization: "Bearer unused", "content-type": "application/json" },
        body: method === "GET" ? null : "{}",
      });
      expect(response.status, `${method} ${path}`).toBe(410);
      await expect(response.json()).resolves.toEqual({ error: "gmail_import_retired" });
    }
  });

  it("leaves non-Gmail routes that share a prefix alone", async () => {
    const response = await SELF.fetch("https://example.test/v1/gmailish");
    expect(response.status).not.toBe(410);
  });

  it("creates and resolves an expiring shared trip without ticket data", async () => {
    const create = await post("/v1/shares", {
      trip: {
        id: "eu:transitous:shared-123",
        source: "transitous",
        nativeId: "shared-123",
        serviceDate: "2026-08-03",
      },
      boardingStationId: "eu:transitous:fr-paris",
      alightingStationId: "eu:transitous:be-brussels",
    });
    expect(create.status).toBe(201);
    const created = await create.json() as { url: string; expiresAt: string };
    const token = new URL(created.url).pathname.slice(3);
    expect(Date.parse(created.expiresAt)).toBeGreaterThan(Date.now());

    const resolved = await SELF.fetch(`https://example.test/v1/shares/${token}`);
    expect(resolved.status).toBe(200);
    await expect(resolved.json()).resolves.toMatchObject({
      trip: { id: "eu:transitous:shared-123", source: "transitous" },
      boardingStationId: "eu:transitous:fr-paris",
    });

    const page = await SELF.fetch(`https://example.test/s/${token}`);
    expect(page.status).toBe(200);
    expect(await page.text()).toContain("Ticket documents");
  });

  it("returns durable health state", async () => {
    const response = await SELF.fetch("https://example.test/health");
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      service: "train-tracker-api",
      status: "ok",
      gmailAccountsRemaining: 0,
    });
  });

  it("returns durable coordinator health over the internal RPC", async () => {
    const health = await env.WATCHER.getByName("global").health();
    expect(health).toMatchObject({
      status: "ok",
      devices: 0,
      activeSubscriptions: 0,
      platformObservations: 0,
      platformObservationSamples: 0,
      platformTrainingEvents: 0,
      platformObservationSources: 0,
      platformObservationLastRecordedAt: null,
      platformShadowForecasts: 0,
      platformShadowOutcomes: 0,
      platformForecastLastGeneratedAt: null,
      platformSampleTargetsActive: 0,
      platformSampleTargetsCompleted: 0,
      platformSampleTargetsFailed: 0,
      platformSampleLastRunAt: null,
      platformSampleLastSuccessAt: null,
      platformSamplingEnabled: false,
      trafiklabRegional: { configured: false },
      darwin: {
        configured: false,
        ready: false,
        compressedBytes: 0,
        messageFiles: 0,
      },
    });
  });

  it("retains an approved platform state once and reports observation health", async () => {
    const watcher = env.WATCHER.getByName("global");
    expect(await watcher.recordPlatformSnapshot(dbPlatformSnapshot, "snapshot")).toBe(1);
    expect(await watcher.recordPlatformSnapshot({
      ...dbPlatformSnapshot,
      fetchedAt: "2026-07-21T16:10:25.000Z",
    }, "watcher")).toBe(1);
    expect(await watcher.recordPlatformSnapshot({
      ...dbPlatformSnapshot,
      fetchedAt: "2026-07-21T16:17:00.000Z",
      stops: [{
        ...dbPlatformSnapshot.stops[0]!,
        passed: true,
      }],
    }, "watcher")).toBe(1);

    expect(await watcher.health()).toMatchObject({
      platformObservations: 1,
      platformObservationSamples: 3,
      platformTrainingEvents: 1,
      platformObservationSources: 1,
      platformObservationLastRecordedAt: "2026-07-21T16:17:00.000Z",
    });
  });

  it("publishes explicit verified, partial, and planned coverage", async () => {
    const response = await SELF.fetch("https://example.test/v1/coverage");
    expect(response.status).toBe(200);
    const value = await response.json() as {
      schemaVersion: number;
      journeySearch: Record<string, unknown> & { countryCodes: string[] };
      liveAudit: { europeanCountriesConnected: number };
      liveDataAudit: { countryCodes: string[]; addedVehiclePositionCountries: string[]; limitations: string[] };
      entries: Array<{ status: string; countryCodes: string[] }>;
    };
    expect(value.schemaVersion).toBe(10);
    expect(value.liveDataAudit.countryCodes).toEqual([...value.journeySearch.countryCodes, "MX"].sort());
    expect(new Set(value.liveDataAudit.countryCodes).size).toBe(51);
    expect(value.liveDataAudit.addedVehiclePositionCountries).toEqual(["AU", "CZ", "FI", "LV", "NO", "SE"]);
    expect(value.liveDataAudit.limitations.join(" ")).toContain("timetable-only");
    expect(value.journeySearch).toEqual({
      phase: 1, places: true, oneWay: true, roundTrip: true, arriveBy: true,
      mainlineOnly: true, trackingResolution: true, fares: false, checkout: false,
      commerce: { enabled: false },
      scheduleSource: "Transitous/MOTIS and server-cached operator timetables", countryCodes: expect.arrayContaining(["US", "FR", "JP", "TW", "KR"]),
    });
    expect(value.liveAudit.europeanCountriesConnected).toBe(39);
    expect(value.entries).toContainEqual(expect.objectContaining({ status: "verified", countryCodes: expect.arrayContaining(["GB"]) }));
    expect(value.entries).toContainEqual(expect.objectContaining({ status: "partial", countryCodes: ["JP"] }));
    expect(value.entries).toContainEqual(expect.objectContaining({ status: "partial", countryCodes: ["MX"] }));
    expect(value.entries).toContainEqual(expect.objectContaining({ status: "verified", countryCodes: ["TW"], scheduleLed: true, platformSources: [] }));
    expect(value.entries).toContainEqual(expect.objectContaining({ status: "verified", countryCodes: ["KR"], scheduleLed: true, platformSources: [] }));
    expect(value.entries).toContainEqual(expect.objectContaining({ status: "not-applicable", countryCodes: expect.arrayContaining(["IS"]) }));
    expect(value.entries).toContainEqual(expect.objectContaining({ status: "planned", countryCodes: ["CN"] }));
  });

  it("serves Mexico Chepe station, board, and complete-trip coverage", async () => {
    const externalFetch = vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
      const url = new URL(typeof input === "string" || input instanceof URL ? input : input.url);
      if (url.origin === "https://chepe.mx") return new Response(chepePublication, { status: 200 });
      if (url.origin === "https://api.transitous.org") return Response.json([]);
      throw new Error(`Unexpected external request: ${url.origin}`);
    });

    try {
      const search = await SELF.fetch("https://example.test/v1/stations/search?scope=international&query=Cerocahui");
      expect(search.status).toBe(200);
      await expect(search.json()).resolves.toContainEqual(expect.objectContaining({
        id: "mx:chepe:bahuichivo",
        source: "chepe",
        countryCode: "MX",
      }));

      const board = await SELF.fetch(
        "https://example.test/v1/stations/board?stationId=mx%3Achepe%3Alos-mochis&source=chepe&nativeId=los-mochis&at=2026-07-23T13%3A00%3A00.000Z&direction=departures",
      );
      expect(board.status).toBe(200);
      const entries = await board.json() as Array<{ trip: { id: string; source: string; nativeId: string; serviceDate: string } }>;
      expect(entries).toHaveLength(1);
      expect(entries[0]?.trip.source).toBe("chepe");

      const trip = entries[0]!.trip;
      const snapshot = await SELF.fetch(
        `https://example.test/v1/trips/snapshot?id=${encodeURIComponent(trip.id)}&source=chepe&nativeId=${encodeURIComponent(trip.nativeId)}&serviceDate=${trip.serviceDate}`,
      );
      expect(snapshot.status).toBe(200);
      await expect(snapshot.json()).resolves.toMatchObject({
        source: "chepe",
        product: "Chepe Express",
        stops: [
          { stationName: "Los Mochis", expectedDeparture: null, expectedPlatform: null },
          { stationName: "Bahuichivo" },
          { stationName: "Creel", expectedArrival: null, expectedPlatform: null },
        ],
      });
    } finally {
      externalFetch.mockRestore();
    }
  });

  it("serves place, journey, and partial plan-resolution routes without exposing sensitive metrics", async () => {
    const replies: TransitousReply[] = [];
    const externalFetch = mockTransitous(replies);
    interceptTransitous(replies, (path) => path.startsWith("/api/v1/geocode?"), [
      {
        type: "PLACE", name: "Paris", id: "paris", lat: 48.8566, lon: 2.3522,
        country: "FR", tz: "Europe/Paris", category: "place_6",
      },
      { type: "STOP", name: "Paris-Nord", id: paris.id, lat: paris.lat, lon: paris.lon, country: "FR", tz: "Europe/Paris", modes: ["LONG_DISTANCE"] },
    ]);
    interceptTransitous(replies, (path) => path.startsWith("/api/v6/plan?"), journeyPlan);
    const info = vi.spyOn(console, "info").mockImplementation(() => undefined);
    const sensitiveIP = "203.0.113.42";
    const headers = { "CF-Connecting-IP": sensitiveIP };

    const places = await SELF.fetch("https://example.test/v1/places/search?q=Paris&scope=mainline&limit=20", { headers });
    expect(places.status).toBe(200);
    expect(places.headers.get("cache-control")).toBe("no-store");
    await expect(places.json()).resolves.toEqual(expect.arrayContaining([
      expect.objectContaining({ kind: "city", displayName: "Paris", countryCode: "FR" }),
      expect.objectContaining({ kind: "station", displayName: "Paris-Nord", countryCode: "FR" }),
    ]));

    const searched = await SELF.fetch("https://example.test/v1/journeys/search", {
      method: "POST", headers: { ...headers, "content-type": "application/json" },
      body: JSON.stringify({
        originId: parisId, destinationId: amsterdamId, time: "2026-07-24T08:00:00+02:00",
        arriveBy: false, maxTransfers: 4, cursor: null,
      }),
    });
    expect(searched.status).toBe(200);
    expect(searched.headers.get("cache-control")).toBe("no-store");
    const page = await searched.json() as JourneySearchPageSnapshot;
    expect(page.options).toHaveLength(1);
    expect(page.options[0]?.trackingToken).toEqual(expect.any(String));
    expect(recursivelyCollectForbiddenJourneyKeys(page)).toEqual([]);

    interceptTransitous(replies, (path) => path.includes("tripId=20260724_fr-mainline_101"), { legs: [firstLeg] });
    interceptTransitous(replies, (path) => path.includes("tripId=20260724_nl-mainline_202"), {}, 503);
    const resolved = await SELF.fetch("https://example.test/v1/journey-plans/resolve", {
      method: "POST", headers: { ...headers, "content-type": "application/json" },
      body: JSON.stringify({ trackingTokens: [page.options[0]!.trackingToken] }),
    });
    expect(resolved.status).toBe(200);
    expect(resolved.headers.get("cache-control")).toBe("no-store");
    const resolvedBody = await resolved.json();
    expect(resolvedBody).toMatchObject({ directions: [{ segments: [
      { trip: expect.objectContaining({ nativeId: "20260724_fr-mainline_101" }), failure: null,
        coverage: { schemaVersion: 1, features: { position: { availability: "notObserved" } } } },
      { trip: null, failure: { code: "provider_unavailable", message: "Trip provider unavailable" },
        coverage: { features: { position: { support: "unknown", availability: "unavailable" } } } },
    ] }] });
    expect(recursivelyCollectForbiddenJourneyKeys(resolvedBody)).toEqual([]);

    const searchMetric = info.mock.calls.find(([, value]) =>
      typeof value === "object" && value !== null && (value as { operation?: string }).operation === "search");
    expect(searchMetric?.[0]).toBe("journey_metric");
    expect(searchMetric?.[1]).toEqual({
      operation: "search", provider: "transitous", originCountryCode: "FR", destinationCountryCode: "NL",
      latencyMilliseconds: expect.any(Number), cacheHit: false, outcome: "success", optionCount: 1,
      errorClass: null, zeroResults: false,
    });
    const serialized = JSON.stringify(info.mock.calls);
    const clientPseudonym = createHmac("sha256", journeySecret).update(sensitiveIP).digest("hex");
    for (const secret of [
      "Paris", sensitiveIP, clientPseudonym, parisId, amsterdamId, "private-cursor", page.options[0]!.trackingToken,
    ]) {
      expect(serialized).not.toContain(secret);
    }
    expect(replies).toEqual([]);
    info.mockRestore();
    externalFetch.mockRestore();
  });

  it("maps Transitous place and journey failures to the stable service-unavailable contract", async () => {
    const replies: TransitousReply[] = [];
    const externalFetch = mockTransitous(replies);
    interceptTransitous(replies, (path) => path.startsWith("/api/v1/geocode?"), {
      private: "/srv/transitous/place-stack.ts",
    }, 503);

    const placeResponse = await SELF.fetch(
      "https://example.test/v1/places/search?q=ProviderFailure&scope=mainline&limit=20",
    );
    expect(placeResponse.status).toBe(503);
    expect(placeResponse.headers.get("cache-control")).toBe("no-store");
    expect(await placeResponse.text()).toBe('{"error":"service_unavailable"}');

    interceptTransitous(replies, (path) => path.startsWith("/api/v6/plan?"), {
      private: "/srv/transitous/plan-stack.ts",
    }, 502);
    const journeyResponse = await post("/v1/journeys/search", {
      originId: parisId,
      destinationId: amsterdamId,
      time: "2026-07-24T09:37:00+02:00",
      arriveBy: false,
      maxTransfers: 4,
      cursor: null,
    });
    expect(journeyResponse.status).toBe(503);
    expect(journeyResponse.headers.get("cache-control")).toBe("no-store");
    expect(await journeyResponse.text()).toBe('{"error":"service_unavailable"}');

    expect(replies).toEqual([]);
    externalFetch.mockRestore();
  });

  it("rejects invalid journey requests, bounded bodies, cursors, and tokens without echoing inputs", async () => {
    const invalidURLs = [
      "/v1/places/search?q=x&scope=mainline&limit=20",
      `/v1/places/search?q=${"private".repeat(20)}&scope=mainline&limit=20`,
      "/v1/places/search?q=Paris&scope=urban&limit=20",
      "/v1/places/search?q=Paris&scope=mainline&limit=21",
    ];
    for (const path of invalidURLs) {
      const response = await SELF.fetch(`https://example.test${path}`);
      expect(response.status).toBe(400);
      expect(response.headers.get("cache-control")).toBe("no-store");
      expect(await response.text()).toBe('{"error":"invalid_request"}');
    }

    const valid = { originId: parisId, destinationId: amsterdamId, time: "2026-07-24T08:00:00+02:00", arriveBy: false, maxTransfers: 4, cursor: null };
    for (const body of [
      { ...valid, destinationId: parisId },
      { ...valid, time: "2026-07-24T08:00:00" },
      { ...valid, maxTransfers: 5 },
      { ...valid, cursor: "x".repeat(8 * 1_024 + 1) },
    ]) expect((await post("/v1/journeys/search", body)).status).toBe(400);
    expect((await post("/v1/journeys/search", { ...valid, cursor: "private-tampered-cursor" })).status).toBe(400);
    for (const trackingTokens of [[], ["a", "b", "c"], ["private-token".repeat(3_000)]]) {
      expect((await post("/v1/journey-plans/resolve", { trackingTokens })).status).toBe(400);
    }
    expect((await post("/v1/journey-plans/resolve", { trackingTokens: ["private-tampered-token"] })).status).toBe(400);

    const declaredLarge = await SELF.fetch("https://example.test/v1/journeys/search", {
      method: "POST", headers: { "content-type": "application/json", "content-length": "49153" }, body: "{}",
    });
    expect(declaredLarge.status).toBe(413);
    expect(await declaredLarge.text()).toBe('{"error":"request_too_large"}');
    const actualLarge = await SELF.fetch("https://example.test/v1/journeys/search", {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ padding: "private-body".repeat(5_000) }),
    });
    expect(actualLarge.status).toBe(413);
    expect(await actualLarge.text()).not.toContain("private-body");
  });

  it("maps missing journey configuration, expired tokens, and rate limits to bounded public errors", async () => {
    const context = createExecutionContext();
    for (const journeyTokenSecret of [undefined, "short-secret"]) {
      const requestWithoutSecret = new Request(
        "https://example.test/v1/places/search?q=Paris&scope=mainline&limit=20",
      ) as unknown as Parameters<typeof worker.fetch>[0];
      const unavailable = await worker.fetch(
        requestWithoutSecret,
        { WATCHER: env.WATCHER, APNS_MODE: "dry-run", JOURNEY_TOKEN_SECRET: journeyTokenSecret } as WorkerEnv,
        context,
      );
      expect(unavailable.status).toBe(503);
      expect(await unavailable.json()).toEqual({ error: "service_unavailable" });
    }

    const replies: TransitousReply[] = [];
    const externalFetch = mockTransitous(replies);
    interceptTransitous(replies, (path) => path.startsWith("/api/v6/plan?"), journeyPlan);
    const search = await post("/v1/journeys/search", {
      originId: parisId, destinationId: amsterdamId, time: "2026-07-24T09:00:00+02:00",
      arriveBy: false, maxTransfers: 4, cursor: null,
    });
    const page = await search.json() as JourneySearchPageSnapshot;
    const option = page.options[0] as JourneyOptionSnapshot;
    const expired = createJourneyTrackingToken(option, journeySecret, new Date(Date.now() - 11 * 60_000)).token;
    const expiredResponse = await post("/v1/journey-plans/resolve", { trackingTokens: [expired] });
    expect(expiredResponse.status).toBe(409);
    expect(await expiredResponse.json()).toEqual({ error: "tracking_token_expired" });

    interceptTransitous(replies, (path) => path.startsWith("/api/v1/geocode?"), []);
    let limited: Response | null = null;
    for (let index = 0; index < 31; index += 1) {
      limited = await SELF.fetch("https://example.test/v1/places/search?q=RateLimitUnique&scope=mainline&limit=1", {
        headers: { "CF-Connecting-IP": "198.51.100.77" },
      });
    }
    expect(limited?.status).toBe(429);
    expect(Number(limited?.headers.get("retry-after"))).toBeGreaterThan(0);
    expect(await limited?.json()).toEqual({ error: "rate_limited" });
    expect(replies).toEqual([]);
    externalFetch.mockRestore();
  });

  it("rejects malformed discovery and snapshot requests before provider calls", async () => {
    for (const path of [
      "/v1/stations/search?scope=international&query=x",
      "/v1/stations/board?source=unknown",
      "/v1/trips/snapshot?source=transitous&serviceDate=bad",
    ]) {
      const response = await SELF.fetch(`https://example.test${path}`);
      expect(response.status).toBe(400);
      await expect(response.json()).resolves.toMatchObject({ error: "invalid_request" });
    }
  });

  it("rejects malformed device registrations", async () => {
    const response = await mutate("/v1/devices", { installationId: "bad" });
    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toMatchObject({ error: "invalid_request" });
  });

  it("persists a subscription and keeps its 20-second alarm alive", async () => {
    const today = new Date().toISOString().slice(0, 10);
    expect((await mutate("/v1/devices", device)).status).toBe(204);
    expect((await mutate("/v1/subscriptions", {
      ...subscription,
      trip: { ...subscription.trip, serviceDate: today },
      watchFrom: new Date(Date.now() + 5 * 60_000).toISOString(),
    })).status).toBe(204);

    const watcher = env.WATCHER.getByName("global");
    // A watch that starts later parks the alarm at its start instead of polling.
    expect(await runDurableObjectAlarm(watcher)).toBe(true);
    const parked = await watcher.health();
    expect(Date.parse(parked.alarmScheduledAt!) - Date.now()).toBeGreaterThan(4 * 60_000);

    expect((await mutate("/v1/subscriptions", {
      ...subscription,
      trip: { ...subscription.trip, serviceDate: today },
      watchFrom: new Date(Date.now() - 60_000).toISOString(),
    })).status).toBe(204);
    const providerFetch = vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("offline"));
    expect(await runDurableObjectAlarm(watcher)).toBe(true);
    providerFetch.mockRestore();

    const health = await watcher.health();
    expect(health.activeSubscriptions).toBe(1);
    expect(health.lastTick?.tripsClaimed).toBe(1);
    expect(health.alarmScheduledAt).not.toBeNull();
    const alarmDelay = Date.parse(health.alarmScheduledAt!) - Date.now();
    expect(alarmDelay).toBeGreaterThan(15_000);
    expect(alarmDelay).toBeLessThanOrEqual(21_000);
  });

  it("requires device possession for every notification mutation", async () => {
    expect((await post("/v1/devices", device)).status).toBe(401);
    expect((await mutate("/v1/devices", device)).status).toBe(204);
    expect((await mutate("/v1/subscriptions", subscription, "x".repeat(43))).status).toBe(401);

    const unauthorizedDelete = await SELF.fetch(
      `https://example.test/v1/subscriptions?installationId=${installationId}&tripId=${encodeURIComponent(subscription.trip.id)}`,
      { method: "DELETE", headers: { authorization: `Device ${"x".repeat(43)}` } },
    );
    expect(unauthorizedDelete.status).toBe(401);
  });

  it("bounds mutation bodies and active subscriptions", async () => {
    const quotaInstallationId = "ca141c63-e992-48ed-8c46-86cb6d42586a";
    const quotaDevice = { ...device, installationId: quotaInstallationId, token: "b".repeat(64) };
    // Maintenance may run between requests. These trips must still count as active.
    const quotaSubscription = {
      ...subscription,
      installationId: quotaInstallationId,
      trip: { ...subscription.trip, serviceDate: new Date().toISOString().slice(0, 10) },
    };
    expect((await mutate("/v1/devices", quotaDevice, deviceCredential, "198.51.100.20")).status).toBe(204);
    const oversized = await SELF.fetch("https://example.test/v1/subscriptions", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Device ${deviceCredential}`,
        "CF-Connecting-IP": "198.51.100.20",
      },
      body: JSON.stringify({ padding: "private-body".repeat(2_000) }),
    });
    expect(oversized.status).toBe(413);
    expect(await oversized.text()).not.toContain("private-body");

    for (let index = 0; index < 24; index += 1) {
      const body = {
        ...quotaSubscription,
        trip: { ...quotaSubscription.trip, id: `us:amtraker:quota-${index}`, nativeId: `quota-${index}` },
      };
      expect((await mutate("/v1/subscriptions", body, deviceCredential, "198.51.100.20")).status).toBe(204);
    }
    const overQuota = await mutate("/v1/subscriptions", {
      ...quotaSubscription,
      trip: { ...quotaSubscription.trip, id: "us:amtraker:quota-over", nativeId: "quota-over" },
    }, deviceCredential, "198.51.100.20");
    expect(overQuota.status).toBe(409);
    await expect(overQuota.json()).resolves.toEqual({ error: "quota_exceeded" });
  });

  it("rate limits mutation networks without logging credentials or addresses", async () => {
    const privateAddress = "203.0.113.99";
    const privateCredential = "p".repeat(43);
    const info = vi.spyOn(console, "info").mockImplementation(() => undefined);
    let response: Response | null = null;
    for (let index = 0; index < 11; index += 1) {
      response = await mutate("/v1/devices", {
        ...device,
        installationId: `ba141c63-e992-48ed-8c46-${String(index).padStart(12, "0")}`,
        token: index.toString(16).padStart(64, "a"),
      }, privateCredential, privateAddress);
    }
    expect(response?.status).toBe(429);
    expect(Number(response?.headers.get("retry-after"))).toBeGreaterThan(0);
    const logs = JSON.stringify(info.mock.calls);
    expect(logs).not.toContain(privateAddress);
    expect(logs).not.toContain(privateCredential);
    info.mockRestore();
  });
});
