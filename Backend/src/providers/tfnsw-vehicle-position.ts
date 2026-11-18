import { transit_realtime } from "gtfs-realtime-bindings";
import type { TripSnapshot, VehiclePositionSnapshot } from "../domain/snapshot.js";
import type { TripPositionOverlay } from "./trip-position-overlay.js";

const defaultFeedURL = "https://api.transport.nsw.gov.au/v1/gtfs/vehiclepos/nswtrains";
const feedMarker = "_au-nsw-Transport-for-New-South-Wales-nsw-trains_";

interface FeedCache {
  key: string;
  loadedAt: number;
  value: Promise<transit_realtime.FeedMessage>;
}

let sharedFeed: FeedCache | null = null;

function timestamp(value: unknown): Date | null {
  if (value === null || value === undefined) return null;
  const seconds = Number(value);
  const date = new Date(seconds * 1_000);
  return Number.isFinite(seconds) && seconds > 0 && !Number.isNaN(date.getTime()) ? date : null;
}

function nativeTripId(snapshot: TripSnapshot): string | null {
  if (snapshot.source !== "transitous") return null;
  const marker = snapshot.nativeId.indexOf(feedMarker);
  return marker < 0 ? null : snapshot.nativeId.slice(marker + feedMarker.length).trim() || null;
}

function matchesServiceDate(trip: transit_realtime.ITripDescriptor, snapshot: TripSnapshot): boolean {
  const match = snapshot.nativeId.match(/^(\d{4})(\d{2})(\d{2})_(\d{1,2}):(\d{2})_/u);
  if (match === null || `${match[1]}-${match[2]}-${match[3]}` !== snapshot.serviceDate) return false;
  const hours = Number(match[4]);
  const minutes = Number(match[5]);
  if (hours > 71 || minutes > 59) return false;
  // MOTIS can encode a 03:55 departure as the previous GTFS day's 27:55.
  // NSW's live descriptor uses the calendar departure date and 03:55 instead.
  const origin = new Date(`${snapshot.serviceDate}T00:00:00.000Z`);
  if (Number.isNaN(origin.getTime())) return false;
  origin.setUTCDate(origin.getUTCDate() + Math.floor(hours / 24));
  const expectedDate = origin.toISOString().slice(0, 10).replaceAll("-", "");
  const expectedTime = `${String(hours % 24).padStart(2, "0")}:${match[5]}:00`;
  return trip.startDate === expectedDate && trip.startTime === expectedTime;
}

export class TfNSWVehiclePositionOverlay implements TripPositionOverlay {
  readonly sourceName = "Transport for NSW GTFS-RT";
  readonly supportedCountryCodes = new Set(["AU"]);
  private feedCache: FeedCache | null = null;

  constructor(
    private readonly apiToken: string,
    private readonly feedURL = defaultFeedURL,
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
  ) {}

  async positionUpdates(snapshot: TripSnapshot): Promise<VehiclePositionSnapshot[]> {
    const id = nativeTripId(snapshot);
    if (id === null) return [];
    const feed = await this.feed();
    const matches = feed.entity.flatMap((entity) => {
      const vehicle = entity.vehicle;
      const trip = vehicle?.trip;
      // This official endpoint also carries coaches (4T.C.*). Keep rail-only
      // scope and require the service date: GTFS trip IDs repeat across days.
      return vehicle !== null && vehicle !== undefined
        && trip?.tripId === id
        && matchesServiceDate(trip, snapshot)
        && trip.routeId?.startsWith("4T.T.") === true
        && trip.scheduleRelationship !== transit_realtime.TripDescriptor.ScheduleRelationship.CANCELED
        && trip.scheduleRelationship !== transit_realtime.TripDescriptor.ScheduleRelationship.DELETED
        ? [vehicle] : [];
    });
    if (matches.length !== 1) return [];
    const vehicle = matches[0]!;
    const position = vehicle.position;
    if (position === null || position === undefined
      || !Object.hasOwn(position, "latitude") || !Object.hasOwn(position, "longitude")) return [];
    const latitude = position.latitude;
    const longitude = position.longitude;
    const asOf = timestamp(vehicle.timestamp);
    // Feed generation is not a vehicle observation. Do not use the header to
    // make an undated or old location appear current.
    if (latitude === null || latitude === undefined || longitude === null || longitude === undefined
      || !Number.isFinite(latitude) || !Number.isFinite(longitude)
      || Math.abs(latitude) > 90 || Math.abs(longitude) > 180
      || (latitude === 0 && longitude === 0) || asOf === null) return [];
    const age = this.now().getTime() - asOf.getTime();
    if (age > 5 * 60_000 || age < -2 * 60_000) return [];
    const bearing = Object.hasOwn(vehicle.position ?? {}, "bearing") ? vehicle.position?.bearing : undefined;
    return [{
      latitude,
      longitude,
      heading: bearing !== null && bearing !== undefined && Number.isFinite(bearing)
        && bearing >= 0 && bearing <= 360 ? bearing : null,
      source: "real",
      confidence: age < 90_000 ? 1 : 0.8,
      asOf: asOf.toISOString(),
      provider: this.sourceName,
    }];
  }

  private feed(): Promise<transit_realtime.FeedMessage> {
    const useShared = this.feedURL === defaultFeedURL;
    const current = useShared ? sharedFeed : this.feedCache;
    const loadedAt = this.now().getTime();
    const cacheAge = current === null ? Number.POSITIVE_INFINITY : loadedAt - current.loadedAt;
    if (current !== null && current.key === this.apiToken && cacheAge >= 0 && cacheAge < 30_000) return current.value;
    const value = this.fetcher(this.feedURL, {
      headers: {
        accept: "application/x-google-protobuf, application/octet-stream",
        authorization: `apikey ${this.apiToken}`,
        "user-agent": "TrainTracker/0.4 (+https://github.com/jaguirre2192)",
      },
      signal: AbortSignal.timeout(12_000),
    }).then(async (response) => {
      if (!response.ok) throw new Error(`TfNSW vehicle feed returned ${response.status}`);
      const feed = transit_realtime.FeedMessage.decode(new Uint8Array(await response.arrayBuffer()));
      const generatedAt = timestamp(feed.header.timestamp);
      const age = generatedAt === null ? Number.POSITIVE_INFINITY : this.now().getTime() - generatedAt.getTime();
      if (age > 5 * 60_000 || age < -2 * 60_000) throw new Error("TfNSW vehicle feed is stale or undated");
      return feed;
    }).catch((error: unknown) => {
      const active = useShared ? sharedFeed : this.feedCache;
      // A slower failed request must not evict a newer successful request.
      if (active?.value === value) {
        if (useShared) sharedFeed = null;
        else this.feedCache = null;
      }
      throw error;
    });
    const next = { key: this.apiToken, loadedAt, value };
    if (useShared) sharedFeed = next;
    else this.feedCache = next;
    return value;
  }
}
