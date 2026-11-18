import { needsRealtimeUpdate } from "./realtime-stop-candidates.js";
import { transit_realtime } from "gtfs-realtime-bindings";
import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";
import { tfNSWPlatforms } from "./tfnsw-platforms.generated.js";

const defaultTripURL = "https://api.transport.nsw.gov.au/v1/gtfs/realtime/nswtrains";
const defaultAlertURL = "https://api.transport.nsw.gov.au/v2/gtfs/alerts/nswtrains";
const feedMarker = "_au-nsw-Transport-for-New-South-Wales-nsw-trains_";

interface FeedCache {
  loadedAt: number;
  token: string;
  value: Promise<transit_realtime.FeedMessage>;
}

let sharedTripFeed: FeedCache | null = null;
let sharedAlertFeed: FeedCache | null = null;

function timestamp(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  const seconds = Number(value);
  return Number.isFinite(seconds) && seconds > 0 ? new Date(seconds * 1_000).toISOString() : null;
}

function expectedTime(
  event: transit_realtime.TripUpdate.IStopTimeEvent | null | undefined,
  scheduled: string | null,
): string | null | undefined {
  const absolute = timestamp(event?.time);
  if (absolute !== null) return absolute;
  if (event?.delay === null || event?.delay === undefined || scheduled === null) return undefined;
  const milliseconds = Date.parse(scheduled) + Number(event.delay) * 1_000;
  return Number.isFinite(milliseconds) ? new Date(milliseconds).toISOString() : undefined;
}

function nativeTripId(snapshot: TripSnapshot): string | null {
  const marker = snapshot.nativeId.indexOf(feedMarker);
  return marker < 0 ? null : snapshot.nativeId.slice(marker + feedMarker.length).trim() || null;
}

function stopCode(stop: StopSnapshot): string | null {
  return stop.stationId.match(/_([\p{Letter}\p{Number}]+)$/u)?.[1] ?? null;
}

function parentStation(code: string): string {
  return tfNSWPlatforms[code]?.parentStation ?? code;
}

function matchingStop(
  snapshot: TripSnapshot,
  update: transit_realtime.TripUpdate.IStopTimeUpdate,
): StopSnapshot | null {
  const realtimeCode = update.stopId?.trim() ?? "";
  if (realtimeCode.length === 0) return null;
  const exact = snapshot.stops.find((stop) => stopCode(stop) === realtimeCode);
  if (exact !== undefined) return exact;
  const parent = parentStation(realtimeCode);
  const candidates = snapshot.stops.filter((stop) => {
    const code = stopCode(stop);
    return code !== null && parentStation(code) === parent;
  });
  if (candidates.length === 1) return candidates[0]!;
  const sequence = Number(update.stopSequence ?? 0);
  return sequence > 0 ? snapshot.stops.find((stop) => stop.sequence === sequence - 1 || stop.sequence === sequence) ?? null : null;
}

function matchesAlertSelector(
  selector: transit_realtime.IEntitySelector,
  snapshot: TripSnapshot,
  trip: transit_realtime.ITripDescriptor,
): boolean {
  const selectorTrip = selector.trip?.tripId?.trim();
  if (selectorTrip !== undefined && selectorTrip.length > 0 && selectorTrip !== trip.tripId) return false;
  const selectorRoute = selector.routeId?.trim();
  if (selectorRoute !== undefined && selectorRoute.length > 0 && selectorRoute !== trip.routeId) return false;
  const selectorStop = selector.stopId?.trim();
  if (selectorStop !== undefined && selectorStop.length > 0) {
    const parent = parentStation(selectorStop);
    if (!snapshot.stops.some((stop) => {
      const code = stopCode(stop);
      return code !== null && parentStation(code) === parent;
    })) return false;
  }
  return selectorTrip !== undefined || selectorRoute !== undefined || selectorStop !== undefined
    || (selector.agencyId?.trim().length ?? 0) > 0;
}

function isActive(alert: transit_realtime.IAlert, now: number): boolean {
  return (alert.activePeriod ?? []).length === 0 || (alert.activePeriod ?? []).some((period) => {
    const start = period.start === null || period.start === undefined ? Number.NEGATIVE_INFINITY : Number(period.start);
    const end = period.end === null || period.end === undefined ? Number.POSITIVE_INFINITY : Number(period.end);
    return now >= start && now <= end;
  });
}

export class TfNSWRealtimeOverlay implements PlatformRealtimeOverlay {
  readonly sourceName = "Transport for NSW GTFS-RT";
  readonly supportedCountryCodes = new Set(["AU"]);
  private tripFeedCache: FeedCache | null = null;
  private alertFeedCache: FeedCache | null = null;

  constructor(
    private readonly apiToken: string,
    private readonly tripURL = defaultTripURL,
    private readonly alertURL = defaultAlertURL,
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
  ) {}

  async platformUpdates(snapshot: TripSnapshot): Promise<PlatformObservation[]> {
    const id = nativeTripId(snapshot);
    if (id === null) return [];
    const feed = await this.feed("trip");
    const entity = feed.entity.find((candidate) => candidate.tripUpdate?.trip.tripId === id);
    const update = entity?.tripUpdate;
    if (update === null || update === undefined) return [];
    const observedAt = timestamp(update.timestamp) ?? timestamp(feed.header.timestamp) ?? this.now().toISOString();
    const tripCancelled = update.trip.scheduleRelationship
      === transit_realtime.TripDescriptor.ScheduleRelationship.CANCELED;
    const stopUpdates = update.stopTimeUpdate ?? [];
    if (tripCancelled && stopUpdates.length === 0) {
      return snapshot.stops.filter((stop) => needsRealtimeUpdate(stop, snapshot)).map((stop) => ({
        stopSequence: stop.sequence,
        stationId: stop.stationId,
        cancelled: true,
        observedAt,
        source: this.sourceName,
      }));
    }
    return stopUpdates.flatMap((stopUpdate): PlatformObservation[] => {
      const stop = matchingStop(snapshot, stopUpdate);
      if (stop === null || !needsRealtimeUpdate(stop, snapshot)) return [];
      const expectedPlatform = tfNSWPlatforms[stopUpdate.stopId?.trim() ?? ""]?.platform ?? null;
      const expectedArrival = expectedTime(stopUpdate.arrival, stop.scheduledArrival);
      const expectedDeparture = expectedTime(stopUpdate.departure, stop.scheduledDeparture);
      const cancelled = tripCancelled || stopUpdate.scheduleRelationship
        === transit_realtime.TripUpdate.StopTimeUpdate.ScheduleRelationship.SKIPPED;
      if (expectedPlatform === null && expectedArrival === undefined && expectedDeparture === undefined && !cancelled) return [];
      return [{
        stopSequence: stop.sequence,
        stationId: stop.stationId,
        plannedPlatform: stop.plannedPlatform,
        expectedPlatform,
        expectedArrival,
        expectedDeparture,
        cancelled,
        observedAt,
        source: this.sourceName,
      }];
    });
  }

  async tripAlertIds(snapshot: TripSnapshot): Promise<string[]> {
    const id = nativeTripId(snapshot);
    if (id === null) return [];
    const trips = await this.feed("trip");
    const descriptor = trips.entity.find((candidate) => candidate.tripUpdate?.trip.tripId === id)?.tripUpdate?.trip;
    if (descriptor === null || descriptor === undefined) return [];
    const alerts = await this.feed("alert");
    const now = Math.floor(this.now().getTime() / 1_000);
    return alerts.entity.flatMap((entity): string[] => {
      const alert = entity.alert;
      if (alert === null || alert === undefined || !isActive(alert, now)) return [];
      return (alert.informedEntity ?? []).some((selector) => matchesAlertSelector(selector, snapshot, descriptor))
        ? [`tfnsw:${entity.id}`]
        : [];
    });
  }

  private feed(kind: "trip" | "alert"): Promise<transit_realtime.FeedMessage> {
    const ttl = kind === "trip" ? 20_000 : 60_000;
    const url = kind === "trip" ? this.tripURL : this.alertURL;
    const useShared = url === (kind === "trip" ? defaultTripURL : defaultAlertURL);
    const current = useShared
      ? (kind === "trip" ? sharedTripFeed : sharedAlertFeed)
      : (kind === "trip" ? this.tripFeedCache : this.alertFeedCache);
    const loadedAt = this.now().getTime();
    const cacheAge = current === null ? Number.POSITIVE_INFINITY : loadedAt - current.loadedAt;
    if (current !== null && current.token === this.apiToken && cacheAge >= 0 && cacheAge < ttl) return current.value;
    const value = this.fetcher(url, {
      headers: {
        accept: "application/x-google-protobuf, application/octet-stream",
        authorization: `apikey ${this.apiToken}`,
        "user-agent": "TrainTracker/0.4 (+https://github.com/jaguirre2192)",
      },
      signal: AbortSignal.timeout(12_000),
    }).then(async (response) => {
      if (!response.ok) throw new Error(`TfNSW ${kind} feed returned ${response.status}`);
      return transit_realtime.FeedMessage.decode(new Uint8Array(await response.arrayBuffer()));
    }).catch((error: unknown) => {
      const active = useShared
        ? (kind === "trip" ? sharedTripFeed : sharedAlertFeed)
        : (kind === "trip" ? this.tripFeedCache : this.alertFeedCache);
      // An older failed request must not clear a newer successful feed.
      if (active?.value === value) {
        if (useShared) {
          if (kind === "trip") sharedTripFeed = null;
          else sharedAlertFeed = null;
        } else if (kind === "trip") this.tripFeedCache = null;
        else this.alertFeedCache = null;
      }
      throw error;
    });
    const next = { loadedAt, token: this.apiToken, value };
    if (useShared) {
      if (kind === "trip") sharedTripFeed = next;
      else sharedAlertFeed = next;
    } else if (kind === "trip") this.tripFeedCache = next;
    else this.alertFeedCache = next;
    return value;
  }
}
