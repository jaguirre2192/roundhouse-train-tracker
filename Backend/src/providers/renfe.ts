import { exactRenfeTrip, matchingRenfeStop, renfeStationMatches, renfeTimingMatch, renfeObservationOnServiceDate, type RenfeStopEvent } from "./renfe-service-identity.js";
import { needsRealtimeUpdate } from "./realtime-stop-candidates.js";
import type { StopSnapshot, TripSnapshot, VehiclePositionSnapshot } from "../domain/snapshot.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";
import type { TripPositionOverlay } from "./trip-position-overlay.js";
import { renfeInstant as instant, renfeLongDistanceVehicleURL,
  type RenfeFeed, type RenfeVehicleEntity, type RenfeTripUpdate, type RenfeTripUpdateEntity } from "./renfe-realtime-models.js";
import { RenfeStaticIdentityVerifier } from "./renfe-static-identity.js";
import { verifiedRenfeUpdate, renfeLongDistanceObservations, type RenfeIdentityVerifier } from "./renfe-long-distance-timing.js";
import { RenfeLongDistancePositions } from "./renfe-long-distance-positions.js";

const defaultVehicleFeedUrl = "https://gtfsrt.renfe.com/vehicle_positions.json";
const defaultLongDistanceVehicleFeedUrl = renfeLongDistanceVehicleURL;
const defaultTripUpdateFeedUrls = [
  "https://gtfsrt.renfe.com/trip_updates.json",
  "https://gtfsrt.renfe.com/trip_updates_LD.json",
] as const;
const defaultAlertFeedUrl = "https://gtfsrt.renfe.com/alerts.json";

interface RenfeInformedEntity {
  routeId?: string | null;
  stopId?: string | null;
  trip?: { tripId?: string | null } | null;
}

interface RenfeAlertEntity {
  id?: string | null;
  alert?: {
    activePeriod?: Array<{ start?: string | number | null; end?: string | number | null }> | null;
    informedEntity?: RenfeInformedEntity[] | null;
  } | null;
}

export interface RenfeCompanionFeeds {
  additionalVehicleFeedUrls?: string[];
  tripUpdateFeedUrls?: string[];
  alertFeedUrl?: string | null;
  staticIdentityVerifier?: RenfeIdentityVerifier;
}

function timestamp(value: unknown): string | null {
  return instant(value)?.toISOString() ?? null;
}

function platform(label: string | null | undefined): string | null {
  const match = label?.match(/PLATF\.\(([^)]+)\)/u);
  const value = match?.[1]?.trim();
  return value === undefined || value.length === 0 ? null : value;
}

function shifted(scheduled: string | null, delay: unknown): string | null | undefined {
  if (scheduled === null || delay === null || delay === undefined) return undefined;
  const epoch = Date.parse(scheduled);
  const seconds = Number(delay);
  return Number.isFinite(epoch) && Number.isFinite(seconds)
    ? new Date(epoch + seconds * 1_000).toISOString()
    : undefined;
}

function expectedTime(
  event: RenfeStopEvent | null | undefined,
  scheduled: string | null,
  tripDelay: unknown,
): string | null | undefined {
  return timestamp(event?.time)
    ?? shifted(scheduled, event?.delay)
    ?? shifted(scheduled, tripDelay);
}

function selectedTripUpdate(
  feeds: Array<RenfeFeed<RenfeTripUpdateEntity>>,
  snapshot: TripSnapshot,
): { feed: RenfeFeed<RenfeTripUpdateEntity>; update: RenfeTripUpdate } | null {
  const matches = feeds.flatMap((feed) => feed.entity.flatMap((entity) => {
    const update = entity.tripUpdate;
    return update !== null && update !== undefined && renfeTimingMatch(update, snapshot, instant(update.timestamp) ?? instant(feed.header.timestamp))
      ? [{ feed, update }]
      : [];
  }));
  const exact = matches.filter(({ update }) =>
    exactRenfeTrip(update.trip, snapshot)
  );
  if (exact.length === 1) return exact[0]!;
  return matches.length === 1 ? matches[0]! : null;
}

function tripUpdateObservations(
  feeds: Array<RenfeFeed<RenfeTripUpdateEntity>>,
  snapshot: TripSnapshot,
  fallbackObservedAt: string,
): PlatformObservation[] {
  const selected = selectedTripUpdate(feeds, snapshot);
  if (selected === null) return [];
  const { feed, update } = selected;
  const observedAt = timestamp(update.timestamp) ?? timestamp(feed.header.timestamp) ?? fallbackObservedAt;
  const tripCancelled = update.trip.scheduleRelationship?.toUpperCase() === "CANCELED"
    || update.trip.scheduleRelationship?.toUpperCase() === "DELETED";
  const updates = update.stopTimeUpdate ?? [];

  if (tripCancelled && updates.length === 0) {
    return snapshot.stops.filter((stop) => needsRealtimeUpdate(stop, snapshot)).map((stop) => ({
      stopSequence: stop.sequence,
      stationId: stop.stationId,
      cancelled: true,
      observedAt,
      source: "Renfe GTFS-RT",
    }));
  }

  return snapshot.stops.flatMap((stop): PlatformObservation[] => {
    const stopUpdate = updates.find((candidate) =>
      matchingRenfeStop(candidate.stopId, candidate.stopSequence, snapshot)?.sequence === stop.sequence
    );
    const cancelled = tripCancelled || stopUpdate?.scheduleRelationship?.toUpperCase() === "SKIPPED";
    const expectedArrival = expectedTime(stopUpdate?.arrival, stop.scheduledArrival, update.delay);
    const expectedDeparture = expectedTime(stopUpdate?.departure, stop.scheduledDeparture, update.delay);
    if (expectedArrival === undefined && expectedDeparture === undefined && !cancelled) return [];
    return [{
      stopSequence: stop.sequence,
      stationId: stop.stationId,
      expectedArrival,
      expectedDeparture,
      cancelled,
      observedAt,
      source: "Renfe GTFS-RT",
    }];
  });
}

function activeAlert(entity: RenfeAlertEntity, now: Date): boolean {
  const periods = entity.alert?.activePeriod ?? [];
  if (periods.length === 0) return true;
  return periods.some((period) => {
    const start = instant(period.start)?.getTime() ?? Number.NEGATIVE_INFINITY;
    const end = instant(period.end)?.getTime() ?? Number.POSITIVE_INFINITY;
    return start <= now.getTime() && now.getTime() < end;
  });
}

function routeToken(snapshot: TripSnapshot): string | null {
  const normalized = snapshot.product.toUpperCase().replace(/[^A-Z0-9]/gu, "");
  return /^[A-Z]{1,2}\d{1,2}[A-Z]?$/u.test(normalized) ? normalized : null;
}

function alertMatches(entity: RenfeAlertEntity, snapshot: TripSnapshot): boolean {
  const informed = entity.alert?.informedEntity ?? [];
  const route = routeToken(snapshot);
  return informed.some((value) => {
    const tripId = value.trip?.tripId?.trim();
    if (tripId !== undefined && exactRenfeTrip({ tripId }, snapshot)) return true;
    const stopId = value.stopId?.trim();
    if (stopId !== undefined && snapshot.stops.some((stop) => renfeStationMatches(stopId, stop))) return true;
    const routeId = value.routeId?.toUpperCase().replace(/[^A-Z0-9]/gu, "");
    return route !== null && routeId !== undefined && routeId.endsWith(route);
  });
}

export class RenfePlatformOverlay implements PlatformRealtimeOverlay, TripPositionOverlay {
  readonly sourceName = "Renfe GTFS-RT";
  readonly supportedCountryCodes = new Set(["ES"]);
  private readonly cache = new Map<string, { loadedAt: number; value: RenfeFeed<unknown> }>();
  private readonly pending = new Map<string, Promise<RenfeFeed<unknown>>>();
  private readonly vehicleFeedUrls: string[];
  private readonly tripUpdateFeedUrls: string[];
  private readonly alertFeedUrl: string | null;
  private readonly staticIdentityVerifier: RenfeIdentityVerifier | null;
  private readonly longDistancePositions = new RenfeLongDistancePositions();

  constructor(
    vehicleFeedUrl = defaultVehicleFeedUrl,
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
    companionFeeds?: RenfeCompanionFeeds,
  ) {
    const useOfficialCompanions = vehicleFeedUrl === defaultVehicleFeedUrl && companionFeeds === undefined;
    this.vehicleFeedUrls = [
      vehicleFeedUrl,
      ...(companionFeeds?.additionalVehicleFeedUrls
        ?? (useOfficialCompanions ? [defaultLongDistanceVehicleFeedUrl] : [])),
    ];
    this.tripUpdateFeedUrls = companionFeeds?.tripUpdateFeedUrls
      ?? (useOfficialCompanions ? [...defaultTripUpdateFeedUrls] : []);
    this.alertFeedUrl = companionFeeds?.alertFeedUrl
      ?? (useOfficialCompanions ? defaultAlertFeedUrl : null);
    this.staticIdentityVerifier = companionFeeds?.staticIdentityVerifier
      ?? (useOfficialCompanions ? new RenfeStaticIdentityVerifier(fetcher, now) : null);
  }

  // Timing has its own enrichment deadline: a stalled position feed cannot erase a delay.
  readonly timingOverlay: PlatformRealtimeOverlay = {
    sourceName: this.sourceName,
    supportedCountryCodes: this.supportedCountryCodes,
    platformUpdates: async (snapshot) => {
      const feeds = await this.feeds<RenfeTripUpdateEntity>(this.forSnapshot(this.tripUpdateFeedUrls, snapshot), "trip updates");
      if (this.isVerifiedLongDistance(snapshot)) {
        return renfeLongDistanceObservations(await verifiedRenfeUpdate(feeds, snapshot,
          this.staticIdentityVerifier!, this.now()), snapshot);
      }
      return tripUpdateObservations(feeds, snapshot, this.now().toISOString());
    },
  };

  private isVerifiedLongDistance(snapshot: TripSnapshot): boolean {
    return this.staticIdentityVerifier !== null && snapshot.nativeId.includes("_es-RENFE-Larga-Distancia-y-AVE_");
  }

  private forSnapshot(urls: string[], snapshot: TripSnapshot): string[] {
    const longDistance = snapshot.nativeId.includes("es-RENFE-Larga-Distancia-y-AVE_");
    const suburban = snapshot.nativeId.includes("es-Cercanías-Renfe_");
    if (!longDistance && !suburban) return urls;
    return urls.filter((url) => {
      const parsed = new URL(url);
      return parsed.hostname !== "gtfsrt.renfe.com" || parsed.pathname.includes("_LD") === longDistance;
    });
  }

  async platformUpdates(snapshot: TripSnapshot): Promise<PlatformObservation[]> {
    // The documented LD feed has no platform assignments. Its broken header must
    // not be interpreted by the Cercanías platform path.
    if (this.isVerifiedLongDistance(snapshot)) return [];
    const vehicleFeeds = await this.feeds<RenfeVehicleEntity>(this.forSnapshot(this.vehicleFeedUrls, snapshot), "vehicle positions");
    const vehicleObservations = vehicleFeeds.flatMap((feed) => feed.entity.flatMap((entity): PlatformObservation[] => {
      const vehicle = entity.vehicle;
      if (vehicle === null || vehicle === undefined || !exactRenfeTrip(vehicle.trip, snapshot)
        || !renfeObservationOnServiceDate(snapshot, instant(vehicle.timestamp) ?? instant(feed.header.timestamp))) return [];
      const expectedPlatform = platform(vehicle.vehicle?.label);
      const stop = matchingRenfeStop(vehicle.stopId, null, snapshot);
      if (expectedPlatform === null || stop === undefined) return [];
      return [{
        stopSequence: stop.sequence,
        stationId: stop.stationId,
        plannedPlatform: stop.plannedPlatform,
        expectedPlatform,
        observedAt: timestamp(vehicle.timestamp) ?? timestamp(feed.header.timestamp) ?? this.now().toISOString(),
        source: this.sourceName,
      }];
    }));
    return vehicleObservations;
  }

  async tripAlertIds(snapshot: TripSnapshot): Promise<string[]> {
    if (this.alertFeedUrl === null) return [];
    const feed = await this.feed<RenfeAlertEntity>(this.alertFeedUrl);
    return feed.entity.filter((entity) => activeAlert(entity, this.now()) && alertMatches(entity, snapshot))
      .map((entity) => `renfe-alert-${entity.id ?? "unknown"}`);
  }

  async positionUpdates(snapshot: TripSnapshot): Promise<VehiclePositionSnapshot[]> {
    const feeds = await this.feeds<RenfeVehicleEntity>(this.forSnapshot(this.vehicleFeedUrls, snapshot), "vehicle positions");
    if (this.isVerifiedLongDistance(snapshot)) {
      const updates = await this.feeds<RenfeTripUpdateEntity>(this.forSnapshot(this.tripUpdateFeedUrls, snapshot), "trip updates");
      const selected = await verifiedRenfeUpdate(updates, snapshot, this.staticIdentityVerifier!, this.now());
      // Only the official feed is eligible for the measured clock-defect recovery.
      const official = feeds.filter((feed) => feed.transport?.url === renfeLongDistanceVehicleURL);
      return official.length === 1 ? this.longDistancePositions.positions(official[0]!, selected, snapshot, this.now()) : [];
    }
    const candidates = feeds.flatMap((feed) => feed.entity.flatMap((entity) => {
      const vehicle = entity.vehicle;
      if (vehicle === null || vehicle === undefined || !exactRenfeTrip(vehicle.trip, snapshot)
        || !renfeObservationOnServiceDate(snapshot, instant(vehicle.timestamp) ?? instant(feed.header.timestamp))) return [];
      if (vehicle.position?.latitude == null || vehicle.position.longitude == null) return [];
      const latitude = Number(vehicle.position.latitude);
      const longitude = Number(vehicle.position?.longitude);
      const asOf = instant(vehicle.timestamp) ?? instant(feed.header.timestamp);
      if (!Number.isFinite(latitude) || !Number.isFinite(longitude) || asOf === null
        || Math.abs(latitude) > 90 || Math.abs(longitude) > 180
        || asOf.getTime() - this.now().getTime() > 120_000) return [];
      return [{ vehicle, latitude, longitude, asOf }];
    }));
    const exact = candidates.filter(({ vehicle }) =>
      exactRenfeTrip(vehicle.trip, snapshot)
    );
    const selected = exact.length === 1 ? exact[0] : undefined;
    if (selected === undefined) return [];
    const age = Math.max(this.now().getTime() - selected.asOf.getTime(), 0);
    if (age > 15 * 60_000) return [];
    const bearing = Number(selected.vehicle.position?.bearing);
    return [{
      latitude: selected.latitude,
      longitude: selected.longitude,
      heading: Number.isFinite(bearing) ? bearing : null,
      source: "real",
      confidence: age < 90_000 ? 1 : age < 5 * 60_000 ? 0.8 : 0.5,
      asOf: selected.asOf.toISOString(),
      provider: this.sourceName,
    }];
  }

  private async feeds<Entity>(urls: string[], label: string): Promise<Array<RenfeFeed<Entity>>> {
    if (urls.length === 0) return [];
    const settled = await Promise.allSettled(urls.map((url) => this.feed<Entity>(url)));
    const values = settled.flatMap((result) => result.status === "fulfilled" ? [result.value] : []);
    for (const result of settled) {
      if (result.status === "rejected") console.error(`Renfe ${label} feed failed`, result.reason);
    }
    if (values.length === 0) throw new Error(`All Renfe ${label} feeds failed`);
    return values;
  }

  private async feed<Entity>(url: string): Promise<RenfeFeed<Entity>> {
    const now = this.now().getTime();
    const cached = this.cache.get(url);
    if (cached !== undefined && now >= cached.loadedAt && now - cached.loadedAt < 15_000) return cached.value as RenfeFeed<Entity>;
    const existing = this.pending.get(url);
    if (existing !== undefined) return existing as Promise<RenfeFeed<Entity>>;
    const request = this.loadFeed<Entity>(url, now)
      .finally(() => this.pending.delete(url));
    this.pending.set(url, request as Promise<RenfeFeed<unknown>>);
    return request;
  }

  private async loadFeed<Entity>(url: string, loadedAt: number): Promise<RenfeFeed<Entity>> {
    const response = await this.fetcher(url, {
      headers: { accept: "application/json", "user-agent": "TrainTracker/0.3 (+https://github.com/jaguirre2192)" },
      signal: AbortSignal.timeout(8_000),
    });
    if (!response.ok) throw new Error(`Renfe GTFS-RT returned ${response.status}`);
    const value = await response.json() as RenfeFeed<Entity>;
    const modified = Date.parse(response.headers.get("last-modified") ?? "");
    value.transport = { url, receivedAt: loadedAt, lastModified: Number.isFinite(modified) ? modified : null };
    const upstreamTimestamp = instant(value.header.timestamp);
    const age = upstreamTimestamp === null ? Number.POSITIVE_INFINITY : loadedAt - upstreamTimestamp.getTime();
    const recoverableLD = url === renfeLongDistanceVehicleURL && age <= 2 * 3_600_000 + 120_000
      && Number.isFinite(modified) && loadedAt - modified <= 120_000 && modified <= loadedAt + 30_000;
    if ((age > 5 * 60_000 && !recoverableLD) || age < -2 * 60_000) throw new Error("Renfe GTFS-RT feed timestamp is stale or in the future");
    this.cache.set(url, { loadedAt, value: value as RenfeFeed<unknown> });
    return value;
  }
}
