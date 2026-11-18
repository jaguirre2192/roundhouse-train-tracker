import type { JourneyOptionSnapshot, JourneySearchRequest, RailPlaceSnapshot } from "../../src/domain/journey.js";
import type { BoardEntrySnapshot, BoardReference, DiscoveryScope, StationSnapshot } from "../../src/domain/discovery.js";
import type { CanonicalTripReference, ProviderSource, TripSnapshot } from "../../src/domain/snapshot.js";
import type {
  JourneySearchProvider,
  ProviderJourneySearchRequest,
  ProviderJourneySearchResult,
} from "../../src/providers/journey-provider.js";
import type { RailProvider } from "../../src/providers/provider.js";
import { ProviderRegistry } from "../../src/providers/provider.js";
import { encodeRailPlaceId } from "../../src/providers/rail-place-id.js";
import { JourneySearchService } from "../../src/services/journey-search-service.js";
import type { JourneyMetric, JourneyMetricLogger } from "../../src/services/journey-metrics.js";
import { JourneyRateLimiter } from "../../src/services/journey-rate-limiter.js";

export const tokenSecret = "task-six-test-secret-with-at-least-32-characters";
export const startMilliseconds = Date.parse("2026-07-21T19:00:00.000Z");

function stationId(nativeId: string, countryCode: string): string {
  return encodeRailPlaceId({
    provider: "transitous",
    kind: "station",
    nativeId,
    countryCode,
    latitude: null,
    longitude: null,
  });
}

function place(nativeId: string, name: string, countryCode: string): RailPlaceSnapshot {
  return {
    id: stationId(nativeId, countryCode),
    kind: "station",
    displayName: name,
    context: `${name}, ${countryCode}`,
    countryCode,
    timeZoneIdentifier: "UTC",
    location: { latitude: 48, longitude: 2 },
    eligibleModes: ["LONG_DISTANCE"],
    attributions: ["Transitous", "OpenStreetMap contributors"],
  };
}

export const paris = place("fr-mainline_paris", "Paris Nord", "FR");
export const amsterdam = place("nl-mainline_amsterdam", "Amsterdam Centraal", "NL");
export const berlin = place("de-mainline_berlin", "Berlin Hbf", "DE");

function railCall(placeValue: RailPlaceSnapshot, arrival: string | null, departure: string | null) {
  return {
    place: placeValue,
    city: null,
    scheduledArrival: arrival,
    scheduledDeparture: departure,
    expectedArrival: arrival,
    expectedDeparture: departure,
    plannedPlatform: null,
    expectedPlatform: null,
    isCancelled: false,
  };
}

export interface SegmentInput {
  segmentId: string;
  reference: CanonicalTripReference;
  from?: RailPlaceSnapshot;
  to?: RailPlaceSnapshot;
}

export function option(
  id: string,
  segments: SegmentInput[],
  start = "2026-07-24T08:00:00.000Z",
): JourneyOptionSnapshot {
  const end = new Date(Date.parse(start) + 2 * 60 * 60_000).toISOString();
  return {
    id,
    fingerprint: `fingerprint-${id}`,
    startTime: start,
    endTime: end,
    duration: 7_200,
    transferCount: Math.max(0, segments.length - 1),
    segments: segments.map((segment) => ({
      id: segment.segmentId,
      kind: "rail" as const,
      rail: {
        tripId: segment.reference.id,
        serviceDate: segment.reference.serviceDate,
        operatorName: "Example Rail",
        product: "Intercity",
        trainNumber: segment.reference.nativeId,
        trainName: null,
        from: railCall(segment.from ?? paris, null, start),
        to: railCall(segment.to ?? amsterdam, end, null),
        intermediateCalls: [],
        isCancelled: false,
        isRealtime: false,
        isTrackable: true,
        untrackableReason: null,
      },
      walk: null,
    })),
    badges: segments.length === 1 ? ["direct"] : [],
    trackability: {
      trackableRailSegments: segments.length,
      totalRailSegments: segments.length,
    },
    realtimeFreshness: null,
    attributions: ["Transitous"],
    trackingToken: "provider-token-must-be-replaced",
  };
}

export function reference(
  source: ProviderSource,
  nativeId: string,
  serviceDate = "2026-07-24",
): CanonicalTripReference {
  return { id: `rail:${source}:${nativeId}`, source, nativeId, serviceDate };
}

export function trip(value: CanonicalTripReference): TripSnapshot {
  return {
    ...value,
    operatorName: "Example Rail",
    product: "Intercity",
    headsign: "Central",
    fetchedAt: "2026-07-21T19:00:00.000Z",
    stops: [],
    positions: [],
    alertIds: [],
  };
}

class CompleteJourneyProvider implements JourneySearchProvider {
  readonly placeCalls: Array<{ query: string; limit: number }> = [];
  readonly journeyCalls: ProviderJourneySearchRequest[] = [];
  places: RailPlaceSnapshot[] = [paris];
  journeyResult: ProviderJourneySearchResult = {
    options: [option("search-result", [{
      segmentId: "search-segment",
      reference: reference("transitous", "search-trip"),
    }])],
    previousProviderCursor: "provider-previous",
    nextProviderCursor: "provider-next",
    attributions: ["Transitous", "OpenStreetMap contributors"],
  };

  async searchPlaces(query: string, limit: number): Promise<RailPlaceSnapshot[]> {
    this.placeCalls.push({ query, limit });
    return structuredClone(this.places);
  }

  async searchJourneys(input: ProviderJourneySearchRequest): Promise<ProviderJourneySearchResult> {
    this.journeyCalls.push(structuredClone(input));
    return structuredClone(this.journeyResult);
  }
}

type TripBehavior = TripSnapshot | Error | { trip: TripSnapshot; delayMilliseconds: number };

class CompleteRailProvider implements RailProvider {
  readonly discoveryScope: DiscoveryScope = "international";
  readonly references: CanonicalTripReference[] = [];
  readonly behaviors = new Map<string, TripBehavior>();

  constructor(readonly source: ProviderSource) {}

  async searchStations(_query: string): Promise<StationSnapshot[]> {
    return [];
  }

  async fetchBoard(_reference: BoardReference): Promise<BoardEntrySnapshot[]> {
    return [];
  }

  async fetchTrip(value: CanonicalTripReference): Promise<TripSnapshot> {
    this.references.push(structuredClone(value));
    const behavior = this.behaviors.get(canonicalReference(value)) ?? trip(value);
    if (behavior instanceof Error) throw behavior;
    if ("delayMilliseconds" in behavior) {
      await new Promise((resolve) => setTimeout(resolve, behavior.delayMilliseconds));
      return structuredClone(behavior.trip);
    }
    return structuredClone(behavior);
  }
}

class RecordingMetricLogger implements JourneyMetricLogger {
  readonly metrics: JourneyMetric[] = [];

  log(metric: JourneyMetric): void {
    this.metrics.push(structuredClone(metric));
  }
}

export function canonicalReference(value: CanonicalTripReference): string {
  return JSON.stringify([value.source, value.nativeId, value.serviceDate]);
}

export function criteria(cursor: string | null = null): JourneySearchRequest {
  return {
    originId: paris.id,
    destinationId: amsterdam.id,
    time: "2026-07-24T08:00:00+02:00",
    arriveBy: false,
    maxTransfers: 2,
    cursor,
  };
}

export function serviceFixture(nowRef = { value: startMilliseconds }) {
  const journeyProvider = new CompleteJourneyProvider();
  const transitous = new CompleteRailProvider("transitous");
  const amtraker = new CompleteRailProvider("amtraker");
  const registry = new ProviderRegistry([transitous, amtraker]);
  const logger = new RecordingMetricLogger();
  const limiter = new JourneyRateLimiter(() => nowRef.value);
  const service = new JourneySearchService(
    journeyProvider,
    registry,
    tokenSecret,
    logger,
    limiter,
    () => new Date(nowRef.value),
  );
  return { service, journeyProvider, transitous, amtraker, logger, nowRef };
}
