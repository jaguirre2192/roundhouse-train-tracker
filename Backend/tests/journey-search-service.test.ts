import { describe, expect, it } from "vitest";
import type { JourneySearchRequest } from "../src/domain/journey.js";
import {
  createJourneyCursor,
  createJourneyTrackingToken,
  resolveJourneyCursor,
  resolveJourneyTrackingToken,
} from "../src/domain/journey-tokens.js";
import { RailProviderNotFoundError } from "../src/providers/provider.js";
import { JourneyTrackingTokenExpiredError } from "../src/services/journey-search-service.js";
import {
  amsterdam,
  berlin,
  canonicalReference,
  criteria,
  option,
  paris,
  reference,
  serviceFixture,
  startMilliseconds,
  tokenSecret,
  trip,
} from "./helpers/journey-search-service-fixtures.js";

describe("JourneySearchService caching and search orchestration", () => {
  it("caches normalized place searches for five minutes using only hashed query keys", async () => {
    const fixture = serviceFixture();
    const rawQuery = "  Secret   Home Station  ";

    const first = await fixture.service.searchPlaces(rawQuery, 10, "hmac-client-place-1");
    fixture.journeyProvider.places = [berlin];
    fixture.nowRef.value += 299_999;
    const cached = await fixture.service.searchPlaces("secret home station", 10, "hmac-client-place-1");

    expect(first).toEqual([paris]);
    expect(cached).toEqual([paris]);
    expect(fixture.journeyProvider.placeCalls).toEqual([{ query: "Secret Home Station", limit: 10 }]);
    const placeCache = Reflect.get(fixture.service, "placeCache") as Map<string, unknown>;
    expect([...placeCache.keys()]).toSatisfy((keys: string[]) =>
      keys.length === 1 && keys.every((key) => /^[a-f0-9]{64}$/u.test(key))
    );
    expect(JSON.stringify([...placeCache.keys()])).not.toContain(rawQuery.trim());
    expect(JSON.stringify(fixture.logger.metrics)).not.toContain(rawQuery.trim());
    expect(fixture.logger.metrics.map((metric) => metric.cacheHit)).toEqual([false, true]);

    fixture.nowRef.value += 1;
    const refreshed = await fixture.service.searchPlaces("SECRET HOME STATION", 10, "hmac-client-place-1");
    expect(refreshed).toEqual([berlin]);
    expect(fixture.journeyProvider.placeCalls).toHaveLength(2);
  });

  it("clears each in-memory cache before inserting entry 201", async () => {
    const fixture = serviceFixture();

    for (let index = 0; index < 200; index += 1) {
      await fixture.service.searchPlaces(`place-${index}`, 1, `hmac-cache-${index}`);
    }
    const cache = Reflect.get(fixture.service, "placeCache") as Map<string, unknown>;
    expect(cache.size).toBe(200);

    await fixture.service.searchPlaces("place-200", 1, "hmac-cache-200");
    expect(cache.size).toBe(1);
    await fixture.service.searchPlaces("place-0", 1, "hmac-cache-repeat");
    expect(fixture.journeyProvider.placeCalls).toHaveLength(202);
  });

  it("validates provider cursors, caches canonical criteria for 30 seconds, and wraps returned cursors", async () => {
    const fixture = serviceFixture();
    const fixedCriteria = { ...criteria(), cursor: undefined };
    const nonCursorCriteria = {
      originId: fixedCriteria.originId,
      destinationId: fixedCriteria.destinationId,
      time: fixedCriteria.time,
      arriveBy: fixedCriteria.arriveBy,
      maxTransfers: fixedCriteria.maxTransfers,
    };
    const firstCursor = createJourneyCursor("provider-page-2", nonCursorCriteria, tokenSecret, new Date(fixture.nowRef.value));
    const first = await fixture.service.searchJourneys(criteria(firstCursor), "hmac-client-search");

    expect(fixture.journeyProvider.journeyCalls[0]?.providerCursor).toBe("provider-page-2");
    expect(resolveJourneyCursor(first.previousCursor!, nonCursorCriteria, tokenSecret, new Date(fixture.nowRef.value)))
      .toBe("provider-previous");
    expect(resolveJourneyCursor(first.nextCursor!, nonCursorCriteria, tokenSecret, new Date(fixture.nowRef.value)))
      .toBe("provider-next");
    expect(first.options[0]?.trackingToken).not.toBe("provider-token-must-be-replaced");
    const payload = resolveJourneyTrackingToken(first.options[0]!.trackingToken, tokenSecret, new Date(fixture.nowRef.value));
    expect(payload.fingerprint).toBe("fingerprint-search-result");
    expect(first.expiresAt).toBe(payload.expiresAt);

    fixture.journeyProvider.journeyResult.options = [];
    fixture.nowRef.value += 1_000;
    const equivalentCursor = createJourneyCursor(
      "provider-page-2",
      nonCursorCriteria,
      tokenSecret,
      new Date(fixture.nowRef.value),
    );
    const cached = await fixture.service.searchJourneys(criteria(equivalentCursor), "hmac-client-search");
    expect(cached.options).toHaveLength(1);
    expect(fixture.journeyProvider.journeyCalls).toHaveLength(1);

    fixture.nowRef.value += 29_000;
    const refreshed = await fixture.service.searchJourneys(criteria(equivalentCursor), "hmac-client-search");
    expect(refreshed.options).toEqual([]);
    expect(fixture.journeyProvider.journeyCalls).toHaveLength(2);
    expect(refreshed.expiresAt).toBe(new Date(fixture.nowRef.value).toISOString());
  });

  it("uses one canonical instant for provider requests, cached cursors, and next-page validation", async () => {
    const fixture = serviceFixture();
    const first = await fixture.service.searchJourneys(criteria(), "hmac-client-canonical-time");
    const equivalentCriteria: JourneySearchRequest = {
      ...criteria(),
      time: "2026-07-24T06:00:00.000Z",
    };

    const cached = await fixture.service.searchJourneys(equivalentCriteria, "hmac-client-canonical-time");
    const next = await fixture.service.searchJourneys({
      ...equivalentCriteria,
      cursor: cached.nextCursor,
    }, "hmac-client-canonical-time");

    expect(cached).toEqual(first);
    expect(next.options).toHaveLength(1);
    expect(fixture.journeyProvider.journeyCalls).toEqual([
      expect.objectContaining({
        time: "2026-07-24T06:00:00.000Z",
        providerCursor: null,
      }),
      expect.objectContaining({
        time: "2026-07-24T06:00:00.000Z",
        providerCursor: "provider-next",
      }),
    ]);
  });

  it("signs every option, uses the earliest token expiry, and emits redacted structured metrics", async () => {
    const fixture = serviceFixture();
    fixture.journeyProvider.journeyResult.options = [
      option("one", [{ segmentId: "one", reference: reference("transitous", "one") }]),
      option("two", [{ segmentId: "two", reference: reference("transitous", "two") }]),
    ];

    const page = await fixture.service.searchJourneys(criteria(), "hmac-client-search-private");
    const expiries = page.options.map((value) =>
      resolveJourneyTrackingToken(value.trackingToken, tokenSecret, new Date(fixture.nowRef.value)).expiresAt
    );

    expect(page.expiresAt).toBe([...expiries].sort()[0]);
    expect(page.options.every((value) => value.trackingToken.length > 0)).toBe(true);
    expect(fixture.logger.metrics).toHaveLength(1);
    expect(fixture.logger.metrics[0]).toEqual({
      operation: "search",
      provider: "transitous",
      originCountryCode: "FR",
      destinationCountryCode: "NL",
      latencyMilliseconds: 0,
      cacheHit: false,
      outcome: "success",
      optionCount: 2,
      errorClass: null,
      zeroResults: false,
    });
    const serialized = JSON.stringify(fixture.logger.metrics[0]);
    for (const sensitive of [criteria().originId, criteria().destinationId, "hmac-client-search-private", "provider-next", page.options[0]!.trackingToken]) {
      expect(serialized).not.toContain(sensitive);
    }
  });

  it("rejects a cursor bound to different criteria before provider search without logging it", async () => {
    const fixture = serviceFixture();
    const mismatched = createJourneyCursor("private-provider-cursor", {
      originId: paris.id,
      destinationId: berlin.id,
      time: "2026-07-24T08:00:00+02:00",
      arriveBy: false,
      maxTransfers: 2,
    }, tokenSecret, new Date(fixture.nowRef.value));

    await expect(fixture.service.searchJourneys(criteria(mismatched), "hmac-client-search"))
      .rejects.toThrow("Invalid journey cursor");

    expect(fixture.journeyProvider.journeyCalls).toEqual([]);
    expect(JSON.stringify(fixture.logger.metrics)).not.toContain("private-provider-cursor");
  });
});

describe("JourneySearchService batch plan resolution", () => {
  it("preserves direction and segment order while deduplicating complete dated references", async () => {
    const fixture = serviceFixture();
    const shared = reference("transitous", "shared", "2026-07-24");
    const nextDate = reference("transitous", "shared", "2026-07-25");
    const amtrak = reference("amtraker", "171", "2026-07-24");
    fixture.transitous.behaviors.set(canonicalReference(shared), { trip: trip(shared), delayMilliseconds: 5 });
    fixture.transitous.behaviors.set(canonicalReference(nextDate), trip(nextDate));
    fixture.amtraker.behaviors.set(canonicalReference(amtrak), trip(amtrak));
    const outbound = createJourneyTrackingToken(option("outbound", [
      { segmentId: "outbound-shared", reference: shared },
      { segmentId: "outbound-shared-again", reference: shared },
      { segmentId: "outbound-amtrak", reference: amtrak, from: amsterdam, to: berlin },
    ]), tokenSecret, new Date(fixture.nowRef.value)).token;
    const inbound = createJourneyTrackingToken(option("return", [
      { segmentId: "return-shared", reference: shared, from: amsterdam, to: paris },
      { segmentId: "return-next-date", reference: nextDate, from: amsterdam, to: paris },
    ], "2026-07-25T08:00:00.000Z"), tokenSecret, new Date(fixture.nowRef.value)).token;

    const result = await fixture.service.resolvePlan([outbound, inbound], "hmac-client-resolve");

    expect(result.directions.map((direction) => direction.fingerprint)).toEqual([
      "fingerprint-outbound",
      "fingerprint-return",
    ]);
    expect(result.directions.map((direction) => direction.segments.map((segment) => segment.segmentId))).toEqual([
      ["outbound-shared", "outbound-shared-again", "outbound-amtrak"],
      ["return-shared", "return-next-date"],
    ]);
    expect(result.directions[0]).toMatchObject({
      originStationId: paris.id,
      destinationStationId: berlin.id,
      departure: "2026-07-24T08:00:00.000Z",
      arrival: "2026-07-24T10:00:00.000Z",
    });
    expect(result.directions.flatMap((direction) => direction.segments).every((segment) =>
      segment.trip !== null && segment.failure === null
    )).toBe(true);
    expect(fixture.transitous.references).toEqual([shared, nextDate]);
    expect(fixture.amtraker.references).toEqual([amtrak]);
  });

  it("returns every successful and failed segment with safe partial-failure classifications", async () => {
    const fixture = serviceFixture();
    const successful = reference("transitous", "successful");
    const missing = reference("transitous", "sensitive-missing-id");
    const unavailable = reference("amtraker", "sensitive-provider-id");
    fixture.transitous.behaviors.set(canonicalReference(successful), trip(successful));
    fixture.transitous.behaviors.set(
      canonicalReference(missing),
      new RailProviderNotFoundError("Requested rail trip is absent"),
    );
    fixture.amtraker.behaviors.set(canonicalReference(unavailable), new Error("secret upstream host failed"));
    const token = createJourneyTrackingToken(option("partial", [
      { segmentId: "success", reference: successful },
      { segmentId: "missing", reference: missing },
      { segmentId: "unavailable", reference: unavailable },
    ]), tokenSecret, new Date(fixture.nowRef.value)).token;

    const result = await fixture.service.resolvePlan([token], "hmac-client-resolve");

    expect(result.directions[0]?.segments).toMatchObject([
      { segmentId: "success", trip: trip(successful), failure: null },
      {
        segmentId: "missing",
        trip: null,
        failure: { code: "not_found", message: "Trip not found" },
      },
      {
        segmentId: "unavailable",
        trip: null,
        failure: { code: "provider_unavailable", message: "Trip provider unavailable" },
      },
    ]);
    expect(JSON.stringify(result)).not.toMatch(/sensitive-missing-id|sensitive-provider-id|secret upstream host/u);
    expect(fixture.logger.metrics.at(-1)).toMatchObject({
      operation: "resolve",
      outcome: "partial_failure",
      errorClass: "provider_unavailable",
      zeroResults: false,
    });
  });

  it("returns explicit failures when no requested trip can be resolved", async () => {
    const fixture = serviceFixture();
    const first = reference("transitous", "missing");
    const second = reference("amtraker", "offline");
    const timeout = new Error("upstream timed out");
    timeout.name = "TimeoutError";
    fixture.transitous.behaviors.set(canonicalReference(first), new RailProviderNotFoundError());
    fixture.amtraker.behaviors.set(canonicalReference(second), timeout);
    const token = createJourneyTrackingToken(option("total-failure", [
      { segmentId: "first", reference: first },
      { segmentId: "second", reference: second },
    ]), tokenSecret, new Date(fixture.nowRef.value)).token;

    const result = await fixture.service.resolvePlan([token], "hmac-client-resolve");

    expect(result.directions[0]?.segments.map((segment) => segment.failure?.code)).toEqual([
      "not_found",
      "provider_unavailable",
    ]);
    expect(result.directions[0]?.segments.every((segment) => segment.trip === null)).toBe(true);
    expect(fixture.logger.metrics.at(-1)).toMatchObject({
      outcome: "failure",
      optionCount: null,
      errorClass: "timeout",
      zeroResults: true,
    });
  });

  it("classifies an expired direction token before making any registry call", async () => {
    const fixture = serviceFixture();
    const validLater = createJourneyTrackingToken(
      option("valid", [{ segmentId: "valid", reference: reference("transitous", "valid") }]),
      tokenSecret,
      new Date(startMilliseconds + 5 * 60_000),
    ).token;
    const expired = createJourneyTrackingToken(
      option("expired", [{ segmentId: "expired", reference: reference("transitous", "expired") }]),
      tokenSecret,
      new Date(startMilliseconds),
    ).token;
    fixture.nowRef.value = startMilliseconds + 10 * 60_000;

    await expect(fixture.service.resolvePlan([validLater, expired], "hmac-client-resolve-private"))
      .rejects.toBeInstanceOf(JourneyTrackingTokenExpiredError);

    expect(fixture.transitous.references).toEqual([]);
    expect(fixture.amtraker.references).toEqual([]);
    expect(fixture.logger.metrics.at(-1)).toEqual({
      operation: "resolve",
      provider: "none",
      originCountryCode: null,
      destinationCountryCode: null,
      latencyMilliseconds: 0,
      cacheHit: false,
      outcome: "failure",
      optionCount: null,
      errorClass: "tracking_token_expired",
      zeroResults: true,
    });
    expect(JSON.stringify(fixture.logger.metrics)).not.toContain("hmac-client-resolve-private");
    expect(JSON.stringify(fixture.logger.metrics)).not.toContain(expired);
  });
});
