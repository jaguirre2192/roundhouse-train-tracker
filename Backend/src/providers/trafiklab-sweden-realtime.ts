import { needsRealtimeUpdate } from "./realtime-stop-candidates.js";
import { transit_realtime } from "gtfs-realtime-bindings";
import type { StopSnapshot, TripSnapshot, VehiclePositionSnapshot } from "../domain/snapshot.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";
import type { TripPositionOverlay } from "./trip-position-overlay.js";

const defaultBaseURL = "https://opendata.samtrafiken.se/gtfs-rt-sweden";
const tripCacheTTL = 30_000;
const tripCacheLimit = 200;
const maximumObservationAge = 5 * 60_000;

// Official source-agency names are provenance, not a train-number guess. An
// exact agency scopes IDs to its feed; unknown agencies still need all feeds.
const agencyOperators = new Map<string, string>([
  ["sl", "sl"], ["ul", "ul"], ["östgötatrafiken", "otraf"], ["jlt", "jlt"],
  ["kronoberg", "krono"], ["klt", "klt"], ["blekingetrafiken", "blekinge"],
  ["skånetrafiken", "skane"], ["värmlandstrafik", "varm"], ["örebro", "orebro"],
  ["västmanland", "vastmanland"], ["dalatrafik", "dt"], ["x-trafik", "xt"],
  ["din tur - västernorrland", "dintur"],
  // These source agencies have static data only in this dataset.
  ["sj", "sj"], ["snälltåget", "snalltaget"], ["vr", "vr"], ["trafikverket", "trv"],
]);

function agencyOperator(snapshot: TripSnapshot): string | undefined {
  return agencyOperators.get(snapshot.operatorName.trim().normalize("NFC").toLowerCase());
}

function freshObservation(value: Date | null, now: Date): value is Date {
  if (value === null) return false;
  const age = now.getTime() - value.getTime();
  return age <= maximumObservationAge && age >= -120_000;
}

const realtimeOperatorCodes = [
  "sl", "ul", "otraf", "jlt", "krono", "klt", "blekinge", "skane", "varm", "orebro",
  "vastmanland", "dt", "xt", "dintur",
] as const;

type FeedKind = "ServiceAlerts" | "TripUpdates" | "VehiclePositions";

interface FeedCache {
  loadedAt: number;
  value: Promise<transit_realtime.FeedMessage>;
}

interface ResolvedTrip {
  operator: string;
  feedTimestamp: Date | null;
  update: transit_realtime.ITripUpdate;
}

function nativeTripId(snapshot: TripSnapshot): string | null {
  const marker = "_se-Trafiklab_";
  const index = snapshot.nativeId.indexOf(marker);
  return index < 0 ? null : snapshot.nativeId.slice(index + marker.length).trim() || null;
}

function serviceDateMatches(value: string | null | undefined, snapshot: TripSnapshot): boolean {
  const date = value?.trim();
  return date === undefined || date.length === 0 || date === snapshot.serviceDate.replaceAll("-", "");
}

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
  if (event === null || event === undefined) return undefined;
  // Decoded protobuf messages inherit delay=0 even when the publisher omitted
  // the field. Only an explicitly present event can supersede another feed.
  const absolute = Object.hasOwn(event, "time") ? timestamp(event.time) : null;
  const planned = scheduled === null ? null : Date.parse(scheduled);
  if (absolute !== null) {
    if (planned !== null && (!Number.isFinite(planned)
      || Math.abs(absolute.getTime() - planned) > 86_400_000)) return undefined;
    return absolute.toISOString();
  }
  if (!Object.hasOwn(event, "delay") || event.delay === null || event.delay === undefined || planned === null) return undefined;
  const delay = Number(event.delay);
  if (!Number.isInteger(delay) || Math.abs(delay) > 86_400 || !Number.isFinite(planned)) return undefined;
  const value = new Date(planned + delay * 1_000);
  return Number.isFinite(value.getTime()) ? value.toISOString() : undefined;
}

function matchingStop(
  snapshot: TripSnapshot,
  update: transit_realtime.TripUpdate.IStopTimeUpdate,
): StopSnapshot | null {
  const stopId = update.stopId?.trim();
  if (stopId !== undefined && stopId.length > 0) {
    const exact = snapshot.stops.filter((stop) => stop.stationId.includes(stopId));
    if (exact.length === 1) return exact[0]!;
  }
  const sequence = Number(update.stopSequence ?? 0);
  if (!Number.isInteger(sequence) || sequence <= 0) return null;
  const exactSequence = snapshot.stops.find((stop) => stop.sequence === sequence);
  if (exactSequence !== undefined) return exactSequence;
  return snapshot.stops.find((stop) => stop.sequence === sequence - 1) ?? null;
}

function tripCancelled(update: transit_realtime.ITripUpdate): boolean {
  return update.trip.scheduleRelationship === transit_realtime.TripDescriptor.ScheduleRelationship.CANCELED
    || update.trip.scheduleRelationship === transit_realtime.TripDescriptor.ScheduleRelationship.DELETED;
}

function isActive(alert: transit_realtime.IAlert, now: number): boolean {
  return (alert.activePeriod ?? []).length === 0 || (alert.activePeriod ?? []).some((period) => {
    const start = period.start === null || period.start === undefined ? Number.NEGATIVE_INFINITY : Number(period.start);
    const end = period.end === null || period.end === undefined ? Number.POSITIVE_INFINITY : Number(period.end);
    return now >= start && now <= end;
  });
}

export class TrafiklabSwedenRealtimeOverlay implements PlatformRealtimeOverlay, TripPositionOverlay {
  readonly sourceName = "Trafiklab GTFS Sweden 3 Realtime";
  readonly supportedCountryCodes = new Set(["SE"]);
  private readonly feedCache = new Map<string, FeedCache>();
  private readonly tripCache = new Map<string, { loadedAt: number; value: Promise<ResolvedTrip | null> }>();

  constructor(
    private readonly apiKey: string,
    private readonly baseURL = defaultBaseURL,
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
    private readonly operatorCodes: readonly string[] = realtimeOperatorCodes,
  ) {}

  async platformUpdates(snapshot: TripSnapshot): Promise<PlatformObservation[]> {
    const resolved = await this.resolveTrip(snapshot);
    if (resolved === null) return [];
    const { feedTimestamp, update } = resolved;
    const observedAt = timestamp(update.timestamp) ?? feedTimestamp;
    // Cached matches retain the publisher timestamp and are checked again on
    // every use. A fresh header never rescues an old trip observation.
    if (!freshObservation(feedTimestamp, this.now()) || !freshObservation(observedAt, this.now())) return [];
    const cancelled = tripCancelled(update);
    const stopUpdates = update.stopTimeUpdate ?? [];
    if (cancelled && stopUpdates.length === 0) {
      return snapshot.stops.filter((stop) => needsRealtimeUpdate(stop, snapshot) && stop.countryCode.toUpperCase() === "SE").map((stop) => ({
        stopSequence: stop.sequence,
        stationId: stop.stationId,
        cancelled: true,
        observedAt: observedAt.toISOString(),
        source: this.sourceName,
      }));
    }
    return stopUpdates.flatMap((stopUpdate): PlatformObservation[] => {
      if (!cancelled && stopUpdate.scheduleRelationship
        === transit_realtime.TripUpdate.StopTimeUpdate.ScheduleRelationship.NO_DATA) return [];
      const stop = matchingStop(snapshot, stopUpdate);
      if (stop === null || !needsRealtimeUpdate(stop, snapshot)) return [];
      const expectedArrival = expectedTime(stopUpdate.arrival, stop.scheduledArrival);
      const expectedDeparture = expectedTime(stopUpdate.departure, stop.scheduledDeparture);
      const stopCancelled = cancelled || stopUpdate.scheduleRelationship
        === transit_realtime.TripUpdate.StopTimeUpdate.ScheduleRelationship.SKIPPED;
      if (expectedArrival === undefined && expectedDeparture === undefined && !stopCancelled) return [];
      return [{
        stopSequence: stop.sequence,
        stationId: stop.stationId,
        expectedArrival,
        expectedDeparture,
        cancelled: stopCancelled,
        observedAt: observedAt.toISOString(),
        source: this.sourceName,
      }];
    });
  }

  async tripAlertIds(snapshot: TripSnapshot): Promise<string[]> {
    const id = nativeTripId(snapshot);
    const resolved = await this.resolveTrip(snapshot);
    if (id === null || resolved === null) return [];
    let feed: transit_realtime.FeedMessage;
    try {
      feed = await this.feed(resolved.operator, "ServiceAlerts");
    } catch (error) {
      console.error("Trafiklab Sweden alert feed failed", { operator: resolved.operator, error });
      return [];
    }
    const now = Math.floor(this.now().getTime() / 1_000);
    return feed.entity.flatMap((entity): string[] => {
      const alert = entity.alert;
      if (alert === null || alert === undefined || !isActive(alert, now)) return [];
      const exactTrip = (alert.informedEntity ?? []).some((selector) => selector.trip?.tripId === id
        && serviceDateMatches(selector.trip.startDate, snapshot));
      return exactTrip ? [`trafiklab-se:${resolved.operator}:${entity.id}`] : [];
    });
  }

  async positionUpdates(snapshot: TripSnapshot): Promise<VehiclePositionSnapshot[]> {
    const id = nativeTripId(snapshot);
    const resolved = await this.resolveTrip(snapshot);
    if (id === null || resolved === null) return [];
    let feed: transit_realtime.FeedMessage;
    try {
      feed = await this.feed(resolved.operator, "VehiclePositions");
    } catch (error) {
      console.error("Trafiklab Sweden vehicle-position feed failed", { operator: resolved.operator, error });
      return [];
    }
    const candidates = feed.entity.flatMap((entity) => {
      const vehicle = entity.vehicle;
      return vehicle !== null && vehicle !== undefined
        && vehicle.trip?.tripId === id && serviceDateMatches(vehicle.trip.startDate, snapshot)
        ? [vehicle]
        : [];
    });
    if (candidates.length !== 1) return [];
    const vehicle = candidates[0]!;
    const latitude = Number(vehicle.position?.latitude);
    const longitude = Number(vehicle.position?.longitude);
    const asOf = timestamp(vehicle.timestamp) ?? timestamp(feed.header.timestamp);
    if (!Number.isFinite(latitude) || !Number.isFinite(longitude) || asOf === null) return [];
    const age = this.now().getTime() - asOf.getTime();
    if (Math.abs(latitude) > 90 || Math.abs(longitude) > 180 || (latitude === 0 && longitude === 0)
      || age > 5 * 60_000 || age < -2 * 60_000) return [];
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

  private resolveTrip(snapshot: TripSnapshot): Promise<ResolvedTrip | null> {
    const id = nativeTripId(snapshot);
    if (id === null || !snapshot.stops.some((stop) => stop.countryCode.toUpperCase() === "SE")) {
      return Promise.resolve(null);
    }
    const now = this.now().getTime();
    for (const [key, entry] of this.tripCache) {
      if (now - entry.loadedAt >= tripCacheTTL) this.tripCache.delete(key);
    }
    const cached = this.tripCache.get(snapshot.id);
    if (cached !== undefined) return cached.value;
    if (this.tripCache.size >= tripCacheLimit) {
      this.tripCache.delete(this.tripCache.keys().next().value!);
    }
    const value = this.loadTrip(snapshot, id);
    this.tripCache.set(snapshot.id, { loadedAt: now, value });
    return value;
  }

  private async loadTrip(snapshot: TripSnapshot, id: string): Promise<ResolvedTrip | null> {
    const knownOperator = agencyOperator(snapshot);
    const operators = knownOperator === undefined ? this.operatorCodes
      : this.operatorCodes.includes(knownOperator) ? [knownOperator] : [];
    if (operators.length === 0) return null;
    const feeds = await Promise.allSettled(operators.map(async (operator) => ({
      operator,
      feed: await this.feed(operator, "TripUpdates"),
    })));
    // An unresolved source could contain a duplicate. With no source-agency
    // provenance, accepting the first completed match would be unsafe.
    if (feeds.some((result) => result.status === "rejected")) return null;
    const matches = feeds.flatMap((result): ResolvedTrip[] => {
      if (result.status === "rejected") return [];
      return result.value.feed.entity.flatMap((entity) => {
        const update = entity.tripUpdate;
        return update !== null && update !== undefined
          && update.trip.tripId === id && serviceDateMatches(update.trip.startDate, snapshot)
          // A trip entry may outlive the feed-cache generation. Retain only its
          // own update and timestamp, not every other vehicle in that feed.
          ? [{ operator: result.value.operator, feedTimestamp: timestamp(result.value.feed.header.timestamp), update }]
          : [];
      });
    });
    if (matches.length !== 1) return null;
    const match = matches[0]!;
    return freshObservation(timestamp(match.update.timestamp) ?? match.feedTimestamp, this.now()) ? match : null;
  }

  private feed(operator: string, kind: FeedKind): Promise<transit_realtime.FeedMessage> {
    const key = `${operator}:${kind}`;
    const now = this.now().getTime();
    const ttl = kind === "VehiclePositions" ? 10_000 : kind === "TripUpdates" ? 20_000 : 60_000;
    const cached = this.feedCache.get(key);
    if (cached !== undefined && now - cached.loadedAt < ttl) return cached.value.then((feed) => {
      if (!freshObservation(timestamp(feed.header.timestamp), this.now())) {
        throw new Error(`Trafiklab Sweden ${kind} (${operator}) cached publication is stale`);
      }
      return feed;
    });
    const url = new URL(`${this.baseURL.replace(/\/$/u, "")}/${encodeURIComponent(operator)}/${kind}Sweden.pb`);
    url.searchParams.set("key", this.apiKey);
    const value = this.fetcher(url, {
      headers: {
        accept: "application/x-protobuf, application/octet-stream",
        "user-agent": "TrainTracker/0.4 (+https://github.com/jaguirre2192)",
      },
      signal: AbortSignal.timeout(2_500),
    }).then(async (response) => {
      if (!response.ok) throw new Error(`Trafiklab Sweden ${kind} (${operator}) returned ${response.status}`);
      const feed = transit_realtime.FeedMessage.decode(new Uint8Array(await response.arrayBuffer()));
      const generatedAt = timestamp(feed.header.timestamp);
      if (!freshObservation(generatedAt, this.now())) {
        throw new Error(`Trafiklab Sweden ${kind} (${operator}) is missing a fresh publication timestamp`);
      }
      return feed;
    });
    this.feedCache.set(key, { loadedAt: now, value });
    return value;
  }
}
