import gtfsRealtime, { type transit_realtime } from "gtfs-realtime-bindings";
import type { TripSnapshot, VehiclePositionSnapshot } from "../domain/snapshot.js";
import type { TripPositionOverlay } from "./trip-position-overlay.js";
import { enturServiceJourneyId } from "./entur-service-identity.js";
import { cachedLoad, ExpiringCache } from "./expiring-cache.js";

export class EnturVehiclePositionOverlay implements TripPositionOverlay {
  readonly sourceName = "Entur vehicle positions";
  readonly supportedCountryCodes = new Set(["NO"]);
  private readonly feeds = new ExpiringCache<Promise<transit_realtime.FeedMessage>>(1);

  constructor(
    private readonly feedURL = "https://api.entur.io/realtime/v1/gtfs-rt/vehicle-positions",
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
  ) {}

  async positionUpdates(snapshot: TripSnapshot): Promise<VehiclePositionSnapshot[]> {
    const id = enturServiceJourneyId(snapshot);
    if (id === null || /:ServiceJourney:BUS[-_]/iu.test(id)
      || !snapshot.stops.some((stop) => stop.countryCode.toUpperCase() === "NO")) return [];
    const feed = await this.feed();
    const matches = feed.entity.flatMap((entity) => {
      const vehicle = entity.vehicle;
      return vehicle?.trip?.tripId === id && vehicle.trip.startDate === snapshot.serviceDate.replaceAll("-", "")
        ? [vehicle] : [];
    });
    if (matches.length !== 1) return [];
    const vehicle = matches[0]!;
    const latitude = vehicle.position?.latitude;
    const longitude = vehicle.position?.longitude;
    const seconds = Number(vehicle.timestamp);
    const age = this.now().getTime() - seconds * 1_000;
    if (!Object.hasOwn(vehicle.position ?? {}, "latitude") || !Object.hasOwn(vehicle.position ?? {}, "longitude")
      || typeof latitude !== "number" || typeof longitude !== "number"
      || !Number.isFinite(latitude) || !Number.isFinite(longitude)
      || Math.abs(latitude) > 90 || Math.abs(longitude) > 180 || (latitude === 0 && longitude === 0)
      || !Number.isFinite(seconds) || seconds <= 0 || age > 5 * 60_000 || age < -2 * 60_000) return [];
    const bearing = Object.hasOwn(vehicle.position ?? {}, "bearing") ? vehicle.position?.bearing : undefined;
    return [{
      latitude, longitude,
      heading: typeof bearing === "number" && Number.isFinite(bearing) && bearing >= 0 && bearing <= 360 ? bearing : null,
      source: "real", confidence: age < 90_000 ? 1 : 0.8,
      asOf: new Date(seconds * 1_000).toISOString(), provider: this.sourceName,
    }];
  }

  private feed(): Promise<transit_realtime.FeedMessage> {
    return cachedLoad(this.feeds, "all", this.now().getTime(), 20_000, async () => {
      const response = await this.fetcher(this.feedURL, {
        headers: { accept: "application/x-protobuf", "et-client-name": "traintracker-app" },
        signal: AbortSignal.timeout(8_000),
      });
      if (!response.ok) throw new Error(`Entur vehicle positions returned ${response.status}`);
      return gtfsRealtime.transit_realtime.FeedMessage.decode(new Uint8Array(await response.arrayBuffer()));
    });
  }
}
