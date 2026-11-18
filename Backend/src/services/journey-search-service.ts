import { createHash } from "node:crypto";
import type {
  JourneyOptionSnapshot,
  JourneySearchPageSnapshot,
  JourneySearchRequest,
  RailPlaceSnapshot,
} from "../domain/journey.js";
import {
  createJourneyCursor,
  createJourneyTrackingToken,
  resolveJourneyCursor,
  resolveJourneyTrackingToken,
  type JourneyTrackingPayload,
} from "../domain/journey-tokens.js";
import type { CanonicalTripReference, TripSnapshot } from "../domain/snapshot.js";
import type { JourneySearchProvider } from "../providers/journey-provider.js";
import { ProviderRegistry, RailProviderNotFoundError } from "../providers/provider.js";
import { decodeRailPlaceId } from "../providers/rail-place-id.js";
import type {
  JourneyMetric,
  JourneyMetricErrorClass,
  JourneyMetricLogger,
  JourneyMetricProvider,
  JourneyMetricOutcome,
} from "./journey-metrics.js";
import { JourneyRateLimitError, JourneyRateLimiter, type JourneyRateClass } from "./journey-rate-limiter.js";
import type { CoverageConfiguration, TripCoverage } from "../domain/trip-coverage.js";
import { assessTripCoverage, failedTripCoverage } from "./trip-coverage-assessment.js";

export type JourneySegmentResolutionFailureCode = "not_found" | "provider_unavailable";

export type JourneySegmentResolutionSnapshot =
  | {
      segmentId: string;
      trip: TripSnapshot;
      failure: null;
      coverage: TripCoverage;
    }
  | {
      segmentId: string;
      trip: null;
      coverage: TripCoverage;
      failure: {
        code: JourneySegmentResolutionFailureCode;
        message: string;
      };
    };

export interface JourneyDirectionResolutionSnapshot {
  fingerprint: string;
  originStationId: string;
  destinationStationId: string;
  departure: string;
  arrival: string;
  segments: JourneySegmentResolutionSnapshot[];
}

export interface JourneyPlanResolutionSnapshot {
  directions: JourneyDirectionResolutionSnapshot[];
}

export class JourneyTrackingTokenExpiredError extends Error {
  constructor() {
    super("Journey tracking token expired");
    this.name = "JourneyTrackingTokenExpiredError";
  }
}

interface CacheEntry<T> {
  value: T;
  expiresAt: number;
}

interface MetricContext {
  operation: JourneyRateClass;
  provider: JourneyMetricProvider;
  originCountryCode: string | null;
  destinationCountryCode: string | null;
  startedAt: number;
}

const placeCacheLifetimeMilliseconds = 5 * 60_000;
const journeyCacheLifetimeMilliseconds = 30_000;
const maximumCacheEntries = 200;

function normalizedQuery(query: string): string {
  return query.normalize("NFKC").trim().replace(/\s+/gu, " ");
}

function digest(value: unknown): string {
  return createHash("sha256").update(JSON.stringify(value)).digest("hex");
}

function canonicalReference(reference: CanonicalTripReference): string {
  return JSON.stringify([reference.source, reference.nativeId, reference.serviceDate]);
}

function countryCode(placeId: string): string | null {
  try {
    return decodeRailPlaceId(placeId).countryCode;
  } catch {
    return null;
  }
}

function isTimeout(error: unknown): boolean {
  return error instanceof Error && (
    error.name === "AbortError"
    || error.name === "TimeoutError"
    || /timed? out|timeout/iu.test(error.message)
  );
}

function errorClass(error: unknown): JourneyMetricErrorClass {
  if (error instanceof JourneyRateLimitError) return "rate_limited";
  if (error instanceof JourneyTrackingTokenExpiredError) return "tracking_token_expired";
  if (isTimeout(error)) return "timeout";
  if (error instanceof Error && /invalid journey/iu.test(error.message)) return "invalid_input";
  return "provider_unavailable";
}

function resolutionFailure(error: unknown): {
  code: JourneySegmentResolutionFailureCode;
  message: string;
} {
  if (error instanceof RailProviderNotFoundError) {
    return { code: "not_found", message: "Trip not found" };
  }
  return { code: "provider_unavailable", message: "Trip provider unavailable" };
}

function resolutionProvider(payloads: JourneyTrackingPayload[]): JourneyMetricProvider {
  const sources = new Set(payloads.flatMap((payload) => payload.railSegments.map((segment) => segment.trip.source)));
  if (sources.size === 0) return "none";
  if (sources.size > 1) return "multiple";
  return [...sources][0]!;
}

function clone<T>(value: T): T {
  return structuredClone(value);
}

export class JourneySearchService {
  private readonly placeCache = new Map<string, CacheEntry<RailPlaceSnapshot[]>>();
  private readonly journeyCache = new Map<string, CacheEntry<JourneySearchPageSnapshot>>();

  constructor(
    private readonly journeyProvider: JourneySearchProvider,
    private readonly providers: ProviderRegistry,
    private readonly tokenSecret: string,
    private readonly logger: JourneyMetricLogger,
    private readonly limiter = new JourneyRateLimiter(),
    private readonly now: () => Date = () => new Date(),
    private readonly coverageConfiguration: CoverageConfiguration = { enabledSources: new Set() },
  ) {}

  async searchPlaces(query: string, limit: number, clientKey: string): Promise<RailPlaceSnapshot[]> {
    const startedAt = this.now().getTime();
    const context: MetricContext = {
      operation: "places",
      provider: "transitous",
      originCountryCode: null,
      destinationCountryCode: null,
      startedAt,
    };
    try {
      this.limiter.consume("places", clientKey);
      const providerQuery = normalizedQuery(query);
      context.provider = this.journeyProvider.metricProviderForPlaces?.(providerQuery) ?? "transitous";
      const key = digest([providerQuery.toLocaleLowerCase("en-US"), limit]);
      const cached = this.cached(this.placeCache, key, startedAt);
      if (cached !== null) {
        this.metric(context, true, "success", cached.length, null, cached.length === 0);
        return cached;
      }
      const places = await this.journeyProvider.searchPlaces(providerQuery, limit);
      const result = clone(places);
      this.store(this.placeCache, key, result, this.now().getTime() + placeCacheLifetimeMilliseconds);
      this.metric(context, false, "success", result.length, null, result.length === 0);
      return clone(result);
    } catch (error) {
      this.metric(context, false, "failure", null, errorClass(error), false);
      throw error;
    }
  }

  async searchJourneys(
    input: JourneySearchRequest,
    clientKey: string,
  ): Promise<JourneySearchPageSnapshot> {
    const operationNow = this.now();
    const startedAt = operationNow.getTime();
    const context: MetricContext = {
      operation: "search",
      provider: "transitous",
      originCountryCode: countryCode(input.originId),
      destinationCountryCode: countryCode(input.destinationId),
      startedAt,
    };
    try {
      this.limiter.consume("search", clientKey);
      context.provider = this.journeyProvider.metricProviderForSearch?.(input) ?? "transitous";
      const criteria = {
        originId: input.originId,
        destinationId: input.destinationId,
        time: new Date(input.time).toISOString(),
        arriveBy: input.arriveBy,
        maxTransfers: input.maxTransfers,
      };
      const providerCursor = input.cursor === null
        ? null
        : resolveJourneyCursor(input.cursor, criteria, this.tokenSecret, operationNow);
      const key = digest({
        ...criteria,
        providerCursor,
      });
      const cached = this.cached(this.journeyCache, key, startedAt);
      if (cached !== null) {
        this.metric(context, true, "success", cached.options.length, null, cached.options.length === 0);
        return cached;
      }
      const providerResult = await this.journeyProvider.searchJourneys({
        ...criteria,
        providerCursor,
      });
      const signedOptions: JourneyOptionSnapshot[] = [];
      const expiries: string[] = [];
      for (const option of providerResult.options) {
        const signed = createJourneyTrackingToken(option, this.tokenSecret, operationNow);
        signedOptions.push({ ...clone(option), trackingToken: signed.token });
        expiries.push(signed.expiresAt);
      }
      const generatedAt = operationNow.toISOString();
      const page: JourneySearchPageSnapshot = {
        generatedAt,
        expiresAt: expiries.sort()[0] ?? generatedAt,
        options: signedOptions,
        previousCursor: providerResult.previousProviderCursor === null
          ? null
          : createJourneyCursor(providerResult.previousProviderCursor, criteria, this.tokenSecret, operationNow),
        nextCursor: providerResult.nextProviderCursor === null
          ? null
          : createJourneyCursor(providerResult.nextProviderCursor, criteria, this.tokenSecret, operationNow),
        warnings: [],
        attributions: clone(providerResult.attributions),
      };
      this.store(this.journeyCache, key, page, this.now().getTime() + journeyCacheLifetimeMilliseconds);
      this.metric(context, false, "success", page.options.length, null, page.options.length === 0);
      return clone(page);
    } catch (error) {
      this.metric(context, false, "failure", null, errorClass(error), false);
      throw error;
    }
  }

  async resolvePlan(tokens: string[], clientKey: string): Promise<JourneyPlanResolutionSnapshot> {
    const operationNow = this.now();
    const context: MetricContext = {
      operation: "resolve",
      provider: "none",
      originCountryCode: null,
      destinationCountryCode: null,
      startedAt: operationNow.getTime(),
    };
    let payloads: JourneyTrackingPayload[];
    try {
      this.limiter.consume("resolve", clientKey);
      payloads = tokens.map((token) => {
        try {
          return resolveJourneyTrackingToken(token, this.tokenSecret, operationNow);
        } catch (error) {
          if (error instanceof Error && error.message === "Journey tracking token expired") {
            throw new JourneyTrackingTokenExpiredError();
          }
          throw error;
        }
      });
    } catch (error) {
      this.metric(context, false, "failure", null, errorClass(error), true);
      throw error;
    }

    context.provider = resolutionProvider(payloads);
    context.originCountryCode = countryCode(payloads[0]?.originStationId ?? "");
    context.destinationCountryCode = countryCode(payloads[0]?.destinationStationId ?? "");
    const references = new Map<string, CanonicalTripReference>();
    for (const payload of payloads) {
      for (const segment of payload.railSegments) {
        const key = canonicalReference(segment.trip);
        if (!references.has(key)) references.set(key, segment.trip);
      }
    }
    const entries = [...references.entries()];
    const settled = await Promise.allSettled(entries.map(([, value]) => this.providers.fetchTrip(value)));
    const resolutions = new Map<string, PromiseSettledResult<TripSnapshot>>();
    entries.forEach(([key], index) => resolutions.set(key, settled[index]!));

    const directions = payloads.map((payload): JourneyDirectionResolutionSnapshot => ({
      fingerprint: payload.fingerprint,
      originStationId: payload.originStationId,
      destinationStationId: payload.destinationStationId,
      departure: payload.departure,
      arrival: payload.arrival,
      segments: payload.railSegments.map((segment): JourneySegmentResolutionSnapshot => {
        const resolved = resolutions.get(canonicalReference(segment.trip));
        if (resolved?.status === "fulfilled") {
          return {
            segmentId: segment.segmentId, trip: clone(resolved.value), failure: null,
            coverage: assessTripCoverage(resolved.value, this.coverageConfiguration, this.now()),
          };
        }
        const failure = resolutionFailure(resolved?.reason);
        return {
          segmentId: segment.segmentId,
          trip: null,
          failure,
          coverage: failedTripCoverage(segment.trip, failure.code === "provider_unavailable", this.now()),
        };
      }),
    }));
    const segmentResults = directions.flatMap((direction) => direction.segments);
    const failures = segmentResults.filter((segment) => segment.failure !== null);
    const successes = segmentResults.length - failures.length;
    const outcome: JourneyMetricOutcome = failures.length === 0
      ? "success"
      : successes === 0 ? "failure" : "partial_failure";
    const failureClass: JourneyMetricErrorClass | null = settled.some((result) =>
      result.status === "rejected" && isTimeout(result.reason)
    )
      ? "timeout"
      : failures.some((segment) => segment.failure?.code === "provider_unavailable")
        ? "provider_unavailable"
        : failures.length > 0 ? "not_found" : null;
    this.metric(context, false, outcome, null, failureClass, successes === 0);
    return { directions };
  }

  private cached<T>(cache: Map<string, CacheEntry<T>>, key: string, now: number): T | null {
    const entry = cache.get(key);
    if (entry === undefined) return null;
    if (entry.expiresAt <= now) {
      cache.delete(key);
      return null;
    }
    return clone(entry.value);
  }

  private store<T>(cache: Map<string, CacheEntry<T>>, key: string, value: T, expiresAt: number): void {
    if (cache.size >= maximumCacheEntries && !cache.has(key)) cache.clear();
    cache.set(key, { value: clone(value), expiresAt });
  }

  private metric(
    context: MetricContext,
    cacheHit: boolean,
    outcome: JourneyMetricOutcome,
    optionCount: number | null,
    classifiedError: JourneyMetricErrorClass | null,
    zeroResults: boolean,
  ): void {
    const metric: JourneyMetric = {
      operation: context.operation,
      provider: context.provider,
      originCountryCode: context.originCountryCode,
      destinationCountryCode: context.destinationCountryCode,
      latencyMilliseconds: Math.max(0, this.now().getTime() - context.startedAt),
      cacheHit,
      outcome,
      optionCount,
      errorClass: classifiedError,
      zeroResults,
    };
    try {
      this.logger.log(metric);
    } catch {
      // Metrics must never change the journey result.
    }
  }
}
