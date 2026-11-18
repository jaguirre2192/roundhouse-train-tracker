import { transit_realtime } from "gtfs-realtime-bindings";
import type { TripSnapshot, VehiclePositionSnapshot } from "../domain/snapshot.js";
import type { TripPositionOverlay } from "./trip-position-overlay.js";
import { ExpiringCache } from "./expiring-cache.js";

const defaultFeedUrl = "https://birch.catenarymaps.org/gtfs_rt?feed_id=f-viarail~rt&feed_type=vehicle";

function timestamp(value: unknown): Date | null {
  if (value === null || value === undefined) return null;
  const seconds = Number(value);
  const date = new Date(seconds * 1_000);
  return Number.isFinite(seconds) && seconds > 0 && !Number.isNaN(date.getTime()) ? date : null;
}

function viaTripId(snapshot: TripSnapshot): string | null {
  const match = snapshot.nativeId.match(/_ca-viarail_(.+)$/iu);
  return match?.[1]?.trim() || null;
}

function vehicleMatches(entity: transit_realtime.IFeedEntity, snapshot: TripSnapshot): boolean {
  const expectedTripId = viaTripId(snapshot);
  const trip = entity.vehicle?.trip;
  if (entity.isDeleted === true || expectedTripId === null || trip?.tripId?.trim() !== expectedTripId) return false;
  const startDate = trip.startDate?.trim();
  return startDate === snapshot.serviceDate.replaceAll("-", "");
}

export class ViaRailVehiclePositionOverlay implements TripPositionOverlay {
  readonly sourceName = "Catenary VIA Rail GTFS-RT";
  readonly supportedCountryCodes = new Set(["CA"]);
  private readonly cachedFeed = new ExpiringCache<Promise<transit_realtime.FeedMessage>>(1);

  constructor(
    private readonly feedUrl = defaultFeedUrl,
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
  ) {}

  async positionUpdates(snapshot: TripSnapshot): Promise<VehiclePositionSnapshot[]> {
    if (snapshot.source !== "transitous" || viaTripId(snapshot) === null
      || !snapshot.stops.some((stop) => stop.countryCode === "CA")) return [];
    const feed = await this.feed();
    const candidates = feed.entity.filter((entity) => vehicleMatches(entity, snapshot));
    if (candidates.length !== 1) return [];
    const vehicle = candidates[0]!.vehicle;
    const point = vehicle?.position;
    const latitude = point?.latitude;
    const longitude = point?.longitude;
    const asOf = Object.hasOwn(vehicle ?? {}, "timestamp") ? timestamp(vehicle?.timestamp) : null;
    if (
      !point || !Object.hasOwn(point, "latitude") || !Object.hasOwn(point, "longitude")
      || typeof latitude !== "number" || !Number.isFinite(latitude) || latitude < -90 || latitude > 90
      || typeof longitude !== "number" || !Number.isFinite(longitude) || longitude < -180 || longitude > 180
      || (latitude === 0 && longitude === 0)
      || asOf === null
    ) return [];
    const age = this.now().getTime() - asOf.getTime();
    if (age > 5 * 60_000 || age < -120_000) return [];
    const confidence = age < 90_000 ? 1 : 0.8;
    const bearing = Object.hasOwn(point, "bearing") ? point.bearing : undefined;
    return [{
      latitude,
      longitude,
      heading: typeof bearing === "number" && Number.isFinite(bearing) && bearing >= 0 && bearing <= 360 ? bearing : null,
      source: "real",
      confidence,
      asOf: asOf.toISOString(),
      provider: this.sourceName,
    }];
  }

  private feed(): Promise<transit_realtime.FeedMessage> {
    const now = this.now().getTime(), cached = this.cachedFeed.get("all", now);
    if (cached !== undefined) return cached;
    const value = Promise.resolve().then(() => this.loadFeed());
    this.cachedFeed.set("all", value, now, 30_000);
    return value;
  }

  private async loadFeed(): Promise<transit_realtime.FeedMessage> {
    const response = await this.fetcher(this.feedUrl, {
      headers: {
        accept: "application/x-protobuf",
        "user-agent": "TrainTrackerWatcher/0.3 (+https://github.com/jaguirre2192)",
      },
      signal: AbortSignal.timeout(12_000),
    });
    if (!response.ok) { await response.body?.cancel(); throw new Error(`VIA Rail vehicle GTFS-RT returned ${response.status}`); }
    if (Number(response.headers.get("content-length")) > 2 * 1_024 * 1_024 || response.body === null) {
      await response.body?.cancel(); throw new Error("Invalid VIA Rail position response");
    }
    const reader = response.body.getReader(), chunks: Uint8Array[] = [];
    let size = 0;
    try {
      for (;;) {
        const { value, done } = await reader.read(); if (done) break;
        size += value.byteLength;
        if (size > 2 * 1_024 * 1_024) throw new Error("VIA Rail position feed exceeds byte limit");
        chunks.push(value);
      }
    } finally { await reader.cancel().catch(() => undefined); reader.releaseLock(); }
    const bytes = new Uint8Array(size); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    return transit_realtime.FeedMessage.decode(bytes);
  }
}
