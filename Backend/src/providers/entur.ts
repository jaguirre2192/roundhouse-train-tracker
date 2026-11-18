import { EnturTripAlerts } from "./entur-trip-alerts.js";
import { enturServiceJourneyId } from "./entur-service-identity.js";
import { realtimeCandidateStops } from "./realtime-stop-candidates.js";
import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";

interface EnturGeocoderResponse {
  features: Array<{
    properties: {
      id: string;
      names: { default: string };
      address?: { countryCode?: string | null } | null;
    };
  }>;
}

interface EnturEstimatedCall {
  date: string;
  aimedArrivalTime: string;
  aimedDepartureTime: string;
  expectedArrivalTime: string;
  expectedDepartureTime: string;
  realtime: boolean;
  cancellation: boolean;
  destinationDisplay?: { frontText?: string | null } | null;
  quay: { publicCode?: string | null };
  serviceJourney: {
    id: string;
  };
}

interface EnturGraphQLResponse {
  data?: { stopPlace?: { estimatedCalls: EnturEstimatedCall[] } | null } | null;
  errors?: Array<{ message: string }>;
}

function platform(value: string | null | undefined): string | null {
  const result = value?.trim();
  return result === undefined || result.length === 0 ? null : result;
}

function scheduledTime(stop: StopSnapshot): number | null {
  const value = stop.scheduledDeparture ?? stop.scheduledArrival;
  if (value === null) return null;
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? null : parsed;
}


function sameEvent(scheduled: string | null, aimed: string): boolean {
  return scheduled === null || Date.parse(scheduled) === Date.parse(aimed);
}

function matchingCall(
  stop: StopSnapshot,
  snapshot: TripSnapshot,
  journeyId: string,
  calls: EnturEstimatedCall[],
): EnturEstimatedCall | undefined {
  const matches = calls.filter((call) =>
    call.serviceJourney?.id === journeyId
    && call.date === snapshot.serviceDate
    && sameEvent(stop.scheduledArrival, call.aimedArrivalTime)
    && sameEvent(stop.scheduledDeparture, call.aimedDepartureTime)
  );
  // Repeated service IDs across days, repeated station visits, and conflicting
  // records must not become an arbitrary nearest-call cancellation or delay.
  return matches.length === 1 ? matches[0] : undefined;
}

const estimatedCallsQuery = `
  query TrainTrackerCalls($id: String!, $startTime: DateTime!, $arrivalDeparture: ArrivalDeparture!) {
    stopPlace(id: $id) {
      estimatedCalls(
        startTime: $startTime
        timeRange: 7200
        numberOfDepartures: 50
        includeCancelledTrips: true
        arrivalDeparture: $arrivalDeparture
      ) {
        date
        aimedArrivalTime
        aimedDepartureTime
        expectedArrivalTime
        expectedDepartureTime
        realtime
        cancellation
        destinationDisplay { frontText }
        quay { publicCode }
        serviceJourney { id }
      }
    }
  }
`;

export class EnturPlatformOverlay implements PlatformRealtimeOverlay {
  readonly sourceName = "Entur";
  readonly supportedCountryCodes = new Set(["NO"]);
  private readonly stopPlaceCache = new Map<string, string | null>();
  private readonly alerts: EnturTripAlerts;

  constructor(
    private readonly geocoderUrl = "https://api.entur.io/geocoder/v3/autocomplete",
    private readonly journeyPlannerUrl = "https://api.entur.io/journey-planner/v3/graphql",
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
    alertsUrl = "https://api.entur.io/realtime/v1/gtfs-rt/alerts",
  ) {
    this.alerts = new EnturTripAlerts(alertsUrl, fetcher, now);
  }

  tripAlertIds(snapshot: TripSnapshot): Promise<string[]> {
    return this.alerts.tripAlertIds(snapshot);
  }

  async platformUpdates(snapshot: TripSnapshot): Promise<PlatformObservation[]> {
    const journeyId = enturServiceJourneyId(snapshot);
    if (journeyId === null) return [];
    const candidates = realtimeCandidateStops(snapshot, (stop) => stop.countryCode === "NO", 2);
    const values = await Promise.all(candidates.map(async (stop): Promise<PlatformObservation | null> => {
      const scheduled = scheduledTime(stop);
      if (scheduled === null) return null;
      const stopPlaceId = await this.stopPlaceId(stop.stationName);
      if (stopPlaceId === null) return null;
      const startTime = new Date(scheduled - 45 * 60_000).toISOString();
      const arrivalDeparture = stop.scheduledDeparture === null ? "arrivals" : "departures";
      const response = await this.fetcher(this.journeyPlannerUrl, {
        method: "POST",
        headers: {
          accept: "application/json",
          "content-type": "application/json",
          "et-client-name": "traintracker-app",
        },
        body: JSON.stringify({ query: estimatedCallsQuery, variables: { id: stopPlaceId, startTime, arrivalDeparture } }),
        signal: AbortSignal.timeout(8_000),
      });
      if (!response.ok) throw new Error(`Entur journey planner returned ${response.status}`);
      const payload = await response.json() as EnturGraphQLResponse;
      if (payload.errors !== undefined) throw new Error(`Entur query failed: ${payload.errors[0]?.message ?? "unknown error"}`);
      const call = matchingCall(stop, snapshot, journeyId, payload.data?.stopPlace?.estimatedCalls ?? []);
      const expectedPlatform = platform(call?.quay.publicCode);
      if (call === undefined || (expectedPlatform === null && !call.realtime && !call.cancellation)) return null;
      return {
        stopSequence: stop.sequence,
        stationId: stop.stationId,
        plannedPlatform: stop.plannedPlatform,
        expectedPlatform,
        expectedArrival: call.realtime && stop.scheduledArrival !== null ? call.expectedArrivalTime : undefined,
        expectedDeparture: call.realtime && stop.scheduledDeparture !== null ? call.expectedDepartureTime : undefined,
        cancelled: call.cancellation,
        observedAt: this.now().toISOString(),
        source: this.sourceName,
      };
    }));
    return values.filter((value): value is PlatformObservation => value !== null);
  }

  private async stopPlaceId(stationName: string): Promise<string | null> {
    if (this.stopPlaceCache.has(stationName)) return this.stopPlaceCache.get(stationName) ?? null;
    const url = new URL(this.geocoderUrl);
    url.search = new URLSearchParams({
      q: stationName,
      lang: "en",
      limit: "3",
      layers: "stopPlace",
      stopPlaceTypes: "railStation",
    }).toString();
    const response = await this.fetcher(url, {
      headers: { accept: "application/json", "et-client-name": "traintracker-app" },
      signal: AbortSignal.timeout(8_000),
    });
    if (!response.ok) throw new Error(`Entur geocoder returned ${response.status}`);
    const payload = await response.json() as EnturGeocoderResponse;
    const value = payload.features.find((feature) =>
      feature.properties.address?.countryCode?.toUpperCase() === "NO"
    )?.properties.id ?? null;
    if (this.stopPlaceCache.size >= 200) this.stopPlaceCache.clear();
    this.stopPlaceCache.set(stationName, value);
    return value;
  }
}
