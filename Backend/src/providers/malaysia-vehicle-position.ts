import { transit_realtime } from "gtfs-realtime-bindings";
import type { TripSnapshot, VehiclePositionSnapshot } from "../domain/snapshot.js";
import type { TripPositionOverlay } from "./trip-position-overlay.js";
import { malaysiaPositionRejection } from "./malaysia-position-plausibility.js";
import { MalaysiaVehicleFeed, malaysiaVehicleFeedUrl, type MalaysiaVehicleFeedOptions } from "./malaysia-vehicle-feed.js";

function timestamp(value: unknown): Date | null {
  if (value === null || value === undefined) return null;
  const seconds = Number(value);
  const date = new Date(seconds * 1_000);
  return Number.isFinite(seconds) && seconds > 0 && !Number.isNaN(date.getTime()) ? date : null;
}

function tripToken(value: string): string {
  return value.toLowerCase().replace(/^(?:weekday|weekend|\d{8})_/u, "").trim();
}

function vehicleMatches(entity: transit_realtime.IFeedEntity, snapshot: TripSnapshot): boolean {
  if (snapshot.source !== "transitous" || entity.isDeleted === true) return false;
  const native = snapshot.nativeId.match(/_my-ktmb_(.+)$/iu)?.[1];
  if (native === undefined) return false;
  const realtimeTrip = entity.vehicle?.trip?.tripId?.trim();
  if (realtimeTrip === undefined || realtimeTrip.length === 0) return false;
  if (tripToken(native) !== tripToken(realtimeTrip)) return false;
  const serviceDate = snapshot.serviceDate.replaceAll("-", "");
  const descriptorDate = entity.vehicle?.trip?.startDate?.trim();
  const prefixDate = realtimeTrip.match(/^(\d{8})_/u)?.[1];
  if (descriptorDate && descriptorDate !== serviceDate) return false;
  if (prefixDate && prefixDate !== serviceDate) return false;
  if (descriptorDate || prefixDate) return true;
  // Undated weekday/weekend identifiers recur daily. Only join the local
  // observation day; an overnight service needs an explicit start date.
  const observed = timestamp(entity.vehicle?.timestamp);
  if (observed === null) return false;
  const localDate = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Kuala_Lumpur" }).format(observed);
  return localDate === snapshot.serviceDate;
}

export class MalaysiaVehiclePositionOverlay implements TripPositionOverlay {
  readonly sourceName = "Malaysia Open API KTMB GTFS-RT";
  readonly supportedCountryCodes = new Set(["MY"]);
  private readonly vehicleFeed: MalaysiaVehicleFeed;

  constructor(
    feedUrl = malaysiaVehicleFeedUrl,
    fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
    options: MalaysiaVehicleFeedOptions = {},
  ) {
    this.vehicleFeed = new MalaysiaVehicleFeed(feedUrl, fetcher, now, options);
  }

  async positionUpdates(snapshot: TripSnapshot): Promise<VehiclePositionSnapshot[]> {
    if (snapshot.source !== "transitous" || !/_my-ktmb_[^\s]+$/iu.test(snapshot.nativeId)) return [];
    const feed = await this.vehicleFeed.feed();
    const candidates = feed.entity.filter((entity) => vehicleMatches(entity, snapshot));
    if (candidates.length !== 1) return [];
    const vehicle = candidates[0]!.vehicle;
    const position = vehicle?.position;
    if (position === null || position === undefined
      || !Object.hasOwn(position, "latitude") || !Object.hasOwn(position, "longitude")) return [];
    const latitude = position.latitude;
    const longitude = position.longitude;
    const asOf = timestamp(vehicle?.timestamp);
    if (latitude === null || latitude === undefined || longitude === null || longitude === undefined
      || !Number.isFinite(latitude) || !Number.isFinite(longitude)
      || Math.abs(latitude) > 90 || Math.abs(longitude) > 180
      || (latitude === 0 && longitude === 0) || asOf === null) return [];
    const age = this.now().getTime() - asOf.getTime();
    if (age > 5 * 60_000 || age < -2 * 60_000
      || malaysiaPositionRejection(snapshot, { latitude, longitude }, asOf.getTime()) !== null) return [];
    const confidence = age < 90_000 ? 1 : 0.8;
    const bearing = Object.hasOwn(vehicle?.position ?? {}, "bearing") ? vehicle?.position?.bearing : undefined;
    return [{
      latitude,
      longitude,
      heading: bearing !== null && bearing !== undefined && Number.isFinite(bearing)
        && bearing >= 0 && bearing <= 360 ? bearing : null,
      source: "real",
      confidence,
      asOf: asOf.toISOString(),
      provider: this.sourceName,
    }];
  }

}
