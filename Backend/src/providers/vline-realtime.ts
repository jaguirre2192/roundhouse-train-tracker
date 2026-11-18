import { needsRealtimeUpdate } from "./realtime-stop-candidates.js";
import { transit_realtime } from "gtfs-realtime-bindings";
import type { StopSnapshot, TripSnapshot, VehiclePositionSnapshot } from "../domain/snapshot.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";
import type { TripPositionOverlay } from "./trip-position-overlay.js";

const defaultTripURL = "https://api.opendata.transport.vic.gov.au/opendata/public-transport/gtfs/realtime/v1/vline/trip-updates";
const defaultVehicleURL = "https://api.opendata.transport.vic.gov.au/opendata/public-transport/gtfs/realtime/v1/vline/vehicle-positions";
const feedMarker = "_au-vic-Transport-Victoria-regional-trains_";

interface FeedCache {
  key: string;
  loadedAt: number;
  value: Promise<transit_realtime.FeedMessage>;
}

let sharedTripFeed: FeedCache | null = null;
let sharedVehicleFeed: FeedCache | null = null;

function timestamp(value: unknown): Date | null {
  if (value === null || value === undefined) return null;
  const seconds = Number(value);
  const date = new Date(seconds * 1_000);
  return Number.isFinite(seconds) && seconds > 0 && !Number.isNaN(date.getTime()) ? date : null;
}

function expectedTime(
  event: transit_realtime.TripUpdate.IStopTimeEvent | null | undefined,
  scheduled: string | null,
): string | null | undefined {
  const absolute = timestamp(event?.time);
  if (absolute !== null) return absolute.toISOString();
  if (event?.delay === null || event?.delay === undefined || scheduled === null) return undefined;
  const milliseconds = Date.parse(scheduled) + Number(event.delay) * 1_000;
  return Number.isFinite(milliseconds) ? new Date(milliseconds).toISOString() : undefined;
}

function nativeTripId(snapshot: TripSnapshot): string | null {
  const marker = snapshot.nativeId.indexOf(feedMarker);
  return marker < 0 ? null : snapshot.nativeId.slice(marker + feedMarker.length).trim() || null;
}

function serviceDateMatches(value: string | null | undefined, snapshot: TripSnapshot): boolean {
  const date = value?.trim();
  return date === undefined || date.length === 0 || date === snapshot.serviceDate.replaceAll("-", "");
}

function snapshotStopId(stop: StopSnapshot): string | null {
  return stop.stationId.match(/_([\p{Letter}\p{Number}:-]+)$/u)?.[1] ?? null;
}

function matchingStop(
  snapshot: TripSnapshot,
  update: transit_realtime.TripUpdate.IStopTimeUpdate,
): StopSnapshot | null {
  const realtimeId = update.stopId?.trim() ?? "";
  if (realtimeId.length > 0) {
    const exact = snapshot.stops.filter((stop) => snapshotStopId(stop) === realtimeId);
    if (exact.length === 1) return exact[0]!;
  }
  const sequence = Number(update.stopSequence ?? 0);
  if (!Number.isInteger(sequence) || sequence <= 0) return null;
  const candidates = snapshot.stops.filter((stop) => stop.sequence === sequence - 1 || stop.sequence === sequence);
  return candidates.length === 1 ? candidates[0]! : snapshot.stops.find((stop) => stop.sequence === sequence - 1) ?? null;
}

function matchingTripUpdate(
  feed: transit_realtime.FeedMessage,
  snapshot: TripSnapshot,
): transit_realtime.ITripUpdate | null {
  const id = nativeTripId(snapshot);
  if (id === null) return null;
  const candidates = feed.entity.flatMap((entity) => {
    const update = entity.tripUpdate;
    return update !== null && update !== undefined
      && update.trip.tripId === id
      && serviceDateMatches(update.trip.startDate, snapshot)
      ? [update]
      : [];
  });
  return candidates.length === 1 ? candidates[0]! : null;
}

function matchingVehicle(
  feed: transit_realtime.FeedMessage,
  snapshot: TripSnapshot,
): transit_realtime.IVehiclePosition | null {
  const id = nativeTripId(snapshot);
  if (id === null) return null;
  const candidates = feed.entity.flatMap((entity) => {
    const vehicle = entity.vehicle;
    return vehicle !== null && vehicle !== undefined
      && vehicle.trip?.tripId === id
      && serviceDateMatches(vehicle.trip.startDate, snapshot)
      ? [vehicle]
      : [];
  });
  return candidates.length === 1 ? candidates[0]! : null;
}

export class VLineRealtimeOverlay implements PlatformRealtimeOverlay, TripPositionOverlay {
  readonly sourceName = "Transport Victoria V/Line GTFS-RT";
  readonly supportedCountryCodes = new Set(["AU"]);
  private tripFeedCache: FeedCache | null = null;
  private vehicleFeedCache: FeedCache | null = null;

  constructor(
    private readonly apiKey: string,
    private readonly tripURL = defaultTripURL,
    private readonly vehicleURL = defaultVehicleURL,
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
  ) {}

  async platformUpdates(snapshot: TripSnapshot): Promise<PlatformObservation[]> {
    if (nativeTripId(snapshot) === null) return [];
    const feed = await this.feed("trip");
    const update = matchingTripUpdate(feed, snapshot);
    if (update === null) return [];
    const observedAt = timestamp(update.timestamp) ?? timestamp(feed.header.timestamp) ?? this.now();
    const tripCancelled = update.trip.scheduleRelationship
      === transit_realtime.TripDescriptor.ScheduleRelationship.CANCELED
      || update.trip.scheduleRelationship === transit_realtime.TripDescriptor.ScheduleRelationship.DELETED;
    if (tripCancelled && (update.stopTimeUpdate ?? []).length === 0) {
      return snapshot.stops.filter((stop) => needsRealtimeUpdate(stop, snapshot)).map((stop) => ({
        stopSequence: stop.sequence,
        stationId: stop.stationId,
        cancelled: true,
        observedAt: observedAt.toISOString(),
        source: this.sourceName,
      }));
    }
    return (update.stopTimeUpdate ?? []).flatMap((stopUpdate): PlatformObservation[] => {
      const stop = matchingStop(snapshot, stopUpdate);
      if (stop === null || !needsRealtimeUpdate(stop, snapshot)) return [];
      const expectedArrival = expectedTime(stopUpdate.arrival, stop.scheduledArrival);
      const expectedDeparture = expectedTime(stopUpdate.departure, stop.scheduledDeparture);
      const cancelled = tripCancelled || stopUpdate.scheduleRelationship
        === transit_realtime.TripUpdate.StopTimeUpdate.ScheduleRelationship.SKIPPED;
      if (expectedArrival === undefined && expectedDeparture === undefined && !cancelled) return [];
      return [{
        stopSequence: stop.sequence,
        stationId: stop.stationId,
        expectedArrival,
        expectedDeparture,
        cancelled,
        observedAt: observedAt.toISOString(),
        source: this.sourceName,
      }];
    });
  }

  async positionUpdates(snapshot: TripSnapshot): Promise<VehiclePositionSnapshot[]> {
    if (nativeTripId(snapshot) === null) return [];
    const feed = await this.feed("vehicle");
    const vehicle = matchingVehicle(feed, snapshot);
    if (vehicle === null) return [];
    const latitude = Number(vehicle.position?.latitude);
    const longitude = Number(vehicle.position?.longitude);
    const asOf = timestamp(vehicle.timestamp) ?? timestamp(feed.header.timestamp);
    if (!Number.isFinite(latitude) || !Number.isFinite(longitude) || asOf === null) return [];
    if (Math.abs(latitude) > 90 || Math.abs(longitude) > 180 || (latitude === 0 && longitude === 0)) return [];
    const age = this.now().getTime() - asOf.getTime();
    if (age > 5 * 60_000 || age < -2 * 60_000) return [];
    const bearing = Number(vehicle.position?.bearing);
    return [{
      latitude,
      longitude,
      heading: Number.isFinite(bearing) && bearing >= 0 && bearing <= 360 ? bearing : null,
      source: "real",
      confidence: age < 90_000 ? 1 : 0.8,
      asOf: asOf.toISOString(),
      provider: this.sourceName,
    }];
  }

  private feed(kind: "trip" | "vehicle"): Promise<transit_realtime.FeedMessage> {
    const url = kind === "trip" ? this.tripURL : this.vehicleURL;
    const useShared = url === (kind === "trip" ? defaultTripURL : defaultVehicleURL);
    const current = useShared
      ? (kind === "trip" ? sharedTripFeed : sharedVehicleFeed)
      : (kind === "trip" ? this.tripFeedCache : this.vehicleFeedCache);
    const loadedAt = this.now().getTime();
    if (current !== null && current.key === this.apiKey && loadedAt - current.loadedAt < 30_000) return current.value;
    const value = this.fetcher(url, {
      headers: {
        accept: "application/x-protobuf, application/octet-stream",
        KeyId: this.apiKey,
        "user-agent": "TrainTracker/0.4 (+https://github.com/jaguirre2192)",
      },
      signal: AbortSignal.timeout(12_000),
    }).then(async (response) => {
      if (!response.ok) throw new Error(`V/Line ${kind} feed returned ${response.status}`);
      const feed = transit_realtime.FeedMessage.decode(new Uint8Array(await response.arrayBuffer()));
      const generatedAt = timestamp(feed.header.timestamp);
      if (generatedAt === null) throw new Error(`V/Line ${kind} feed omitted its timestamp`);
      const age = this.now().getTime() - generatedAt.getTime();
      if (age > 5 * 60_000 || age < -2 * 60_000) throw new Error(`V/Line ${kind} feed is stale or in the future`);
      return feed;
    });
    const next = { key: this.apiKey, loadedAt, value };
    if (useShared) {
      if (kind === "trip") sharedTripFeed = next;
      else sharedVehicleFeed = next;
    } else if (kind === "trip") this.tripFeedCache = next;
    else this.vehicleFeedCache = next;
    return value;
  }
}
