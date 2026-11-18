import gtfsRealtime, { type transit_realtime } from "gtfs-realtime-bindings";
import type { TripSnapshot, VehiclePositionSnapshot } from "../domain/snapshot.js";
import type { TripPositionOverlay } from "./trip-position-overlay.js";
import { matchedViviUpdate } from "./pieturas-vivi-matching.js";

const gtfs = gtfsRealtime.transit_realtime;
const defaultURL = "https://rt.pieturas.lv/gtfs-rt.pb";
const defaultFetcher: typeof fetch = (input, init) => fetch(input, init);
const maximumBytes = 6 * 1_024 * 1_024;
interface FeedCache { loadedAt: number; value: Promise<transit_realtime.FeedMessage> }
let sharedCache: FeedCache | null = null;

async function body(response: Response): Promise<Uint8Array> {
  if (!response.ok || !response.body || Number(response.headers.get("content-length")) > maximumBytes) {
    await response.body?.cancel(); throw new Error("Invalid or oversized Pieturas feed response");
  }
  const reader = response.body.getReader(), chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read(); if (done) break;
      size += value.length;
      if (size > maximumBytes) throw new Error("Pieturas feed exceeds byte limit");
      chunks.push(value);
    }
  } finally { await reader.cancel().catch(() => undefined); reader.releaseLock(); }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return bytes;
}

function fresh(value: unknown, now: number): number | null {
  const time = Number(value) * 1_000;
  return Number.isFinite(time) && time > 0 && now - time <= 180_000 && time - now <= 30_000 ? time : null;
}

/** Publisher permits merged realtime reuse with attribution; only its exact Vivi lane is used.
 * https://gsvalbe.id.lv/pieturas/avoti.html — original operator: Vivi (vivi.lv). */
export class PieturasViviPositionOverlay implements TripPositionOverlay {
  readonly sourceName = "Pieturas (pieturas.lv) / Vivi";
  readonly supportedCountryCodes = new Set(["LV"]);
  private cache: FeedCache | null = null;
  constructor(private readonly feedURL = defaultURL, private readonly fetcher: typeof fetch = defaultFetcher,
    private readonly now: () => Date = () => new Date()) {}

  async positionUpdates(snapshot: TripSnapshot): Promise<VehiclePositionSnapshot[]> {
    if (snapshot.source !== "transitous" || !/_lv-pieturas_pv-\d+$/u.test(snapshot.nativeId)
      || !snapshot.stops.some((stop) => stop.countryCode === "LV")) return [];
    const feed = await this.feed(), now = this.now().getTime();
    if (fresh(feed.header.timestamp, now) === null) return [];
    const update = matchedViviUpdate(snapshot, feed);
    if (!update || !Object.hasOwn(update, "timestamp") || fresh(update.timestamp, now) === null) return [];
    const candidates = feed.entity.flatMap(({ vehicle }) => vehicle?.trip?.tripId === update.trip.tripId
      && vehicle?.trip?.startDate === update.trip.startDate ? [vehicle] : []);
    if (candidates.length !== 1) return [];
    const vehicle = candidates[0]!, point = vehicle.position;
    const asOf = Object.hasOwn(vehicle, "timestamp") ? fresh(vehicle.timestamp, now) : null;
    const times = snapshot.stops.flatMap((stop) => [stop.scheduledArrival, stop.scheduledDeparture])
      .flatMap((time) => time === null ? [] : [Date.parse(time)]);
    if (asOf === null || times.length < 2 || !times.every(Number.isFinite)
      || asOf < Math.min(...times) - 900_000 || asOf > Math.max(...times) + 900_000
      || (vehicle.trip?.scheduleRelationship ?? 0) !== 0
      || (vehicle.trip?.routeId && update.trip.routeId && vehicle.trip.routeId !== update.trip.routeId)
      || !point || !Object.hasOwn(point, "latitude") || !Object.hasOwn(point, "longitude")) return [];
    const latitude = Number(point.latitude), longitude = Number(point.longitude);
    // Deliberately loose Latvia bounds also reject absent required protobuf
    // coordinates that an upstream encoder may have materialized as zero.
    if (!Number.isFinite(latitude) || !Number.isFinite(longitude) || latitude < 55 || latitude > 58.5
      || longitude < 20 || longitude > 29) return [];
    const bearing = Object.hasOwn(point, "bearing") ? Number(point.bearing) : NaN;
    return [{ latitude, longitude, heading: Number.isFinite(bearing) && bearing >= 0 && bearing <= 360 ? bearing : null,
      source: "real", confidence: now - asOf < 90_000 ? 1 : 0.8, asOf: new Date(asOf).toISOString(), provider: this.sourceName }];
  }

  private feed(): Promise<transit_realtime.FeedMessage> {
    const now = this.now().getTime(), shared = this.feedURL === defaultURL && this.fetcher === defaultFetcher;
    const cached = shared ? sharedCache : this.cache;
    if (cached && now - cached.loadedAt < 30_000) return cached.value;
    const value = this.fetcher(this.feedURL, { headers: { accept: "application/x-protobuf",
      "user-agent": "TrainTracker/0.4 (+https://github.com/jaguirre2192)" }, signal: AbortSignal.timeout(2_500) })
      .then(body).then((bytes) => {
        const feed = gtfs.FeedMessage.decode(bytes);
        // Keep this rail lane small; the public merged response also includes
        // thousands of Baltic bus entities that this adapter never consumes.
        feed.entity = feed.entity.filter((entity) => /^pv-\d+$/u.test(entity.tripUpdate?.trip.tripId ?? entity.vehicle?.trip?.tripId ?? ""));
        return feed;
      });
    const entry = { loadedAt: now, value };
    if (shared) sharedCache = entry; else this.cache = entry;
    return value;
  }
}
