import type { CanonicalTripReference, TripSnapshot, VehiclePositionSnapshot } from "../domain/snapshot.js";
import { cachedLoad, ExpiringCache } from "./expiring-cache.js";
import { golemioReferenceIdentity, golemioTripIdentity, providerTime, record } from "./golemio-trip-match.js";
import type { TripPositionOverlay } from "./trip-position-overlay.js";
import { ProviderRequestPacer } from "./provider-request-pacer.js";

const defaultBaseUrl = "https://api.golemio.cz";
const maximumResponseBytes = 64 * 1_024;
const maximumPositionAge = 3 * 60_000;
// Standalone instances share a bounded serial allowance in this isolate.
// Production supplies a persistent singleton reservation for shared egress.
const localRequestPacer = new ProviderRequestPacer();

export interface GolemioRealtimeOptions {
  baseUrl?: string;
  fetcher?: typeof fetch;
  now?: () => Date;
  reserveRequest?: () => Promise<void>;
}

async function boundedJSON(response: Response): Promise<unknown> {
  if (Number(response.headers.get("content-length")) > maximumResponseBytes) {
    await response.body?.cancel();
    throw new Error("Golemio position exceeds byte limit");
  }
  if (response.body === null) throw new Error("Golemio position has no body");
  const reader = response.body.getReader(), decoder = new TextDecoder();
  let length = 0, text = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > maximumResponseBytes) {
      await reader.cancel();
      throw new Error("Golemio position exceeds byte limit");
    }
    text += decoder.decode(value, { stream: true });
  }
  try { return JSON.parse(text + decoder.decode()) as unknown; }
  catch { throw new Error("Golemio position returned invalid JSON"); }
}

export class GolemioRealtimeOverlay implements TripPositionOverlay {
  readonly sourceName = "Golemio/PID";
  readonly supportedCountryCodes = new Set(["CZ"]);
  private readonly cache = new ExpiringCache<Promise<unknown>>(128);
  private readonly options: Required<GolemioRealtimeOptions>;

  constructor(private readonly apiKey: string, options: GolemioRealtimeOptions = {}) {
    this.options = { baseUrl: options.baseUrl ?? defaultBaseUrl,
      fetcher: options.fetcher ?? ((input, init) => fetch(input, init)),
      now: options.now ?? (() => new Date()), reserveRequest: options.reserveRequest ?? (() => localRequestPacer.wait()) };
  }

  async prefetch(reference: CanonicalTripReference): Promise<void> {
    const identity = golemioReferenceIdentity(reference);
    if (identity !== null && this.apiKey.trim().length > 0) await this.payload(identity.gtfsTripId);
  }

  private payload(gtfsTripId: string): Promise<unknown> {
    return cachedLoad(this.cache, gtfsTripId, this.options.now().getTime(), 25_000, () => this.load(gtfsTripId));
  }

  async positionUpdates(snapshot: TripSnapshot): Promise<VehiclePositionSnapshot[]> {
    const identity = golemioTripIdentity(snapshot);
    if (identity === null || this.apiKey.trim().length === 0) return [];
    const payload = await this.payload(identity.gtfsTripId);
    const feature = record(payload), properties = record(feature?.properties);
    const trip = record(properties?.trip), gtfs = record(trip?.gtfs);
    const position = record(properties?.last_position), geometry = record(feature?.geometry);
    if (feature?.type !== "Feature" || gtfs?.route_type !== 2 || gtfs.trip_id !== identity.gtfsTripId
      || position?.tracking !== true || position.is_canceled !== false
      || !["at_stop", "on_track"].includes(String(position.state_position))) return [];
    const start = providerTime(trip?.start_timestamp), asOf = providerTime(position.origin_timestamp);
    const now = this.options.now().getTime();
    // Match the whole origin event, including its UTC date, rather than today's
    // Prague calendar date; a selected overnight run keeps its own service day.
    if (!Number.isFinite(now) || start === null || Math.abs(start - identity.originArrival) > 60_000 || asOf === null
      || asOf < start - 60_000 || now - asOf > maximumPositionAge || asOf > now + 30_000) return [];
    const coordinates = geometry?.coordinates;
    if (geometry?.type !== "Point" || !Array.isArray(coordinates) || coordinates.length !== 2) return [];
    const [longitude, latitude] = coordinates;
    if (typeof latitude !== "number" || typeof longitude !== "number"
      || !Number.isFinite(latitude) || !Number.isFinite(longitude)
      || Math.abs(latitude) > 90 || Math.abs(longitude) > 180 || (latitude === 0 && longitude === 0)) return [];
    const bearing = position.bearing;
    return [{ latitude, longitude, heading: typeof bearing === "number" && Number.isFinite(bearing)
      && bearing >= 0 && bearing <= 360 ? bearing % 360 : null,
    source: "real", confidence: now - asOf < 60_000 ? 1 : 0.8,
    asOf: new Date(asOf).toISOString(), provider: this.sourceName }];
  }

  private async load(gtfsTripId: string): Promise<unknown> {
    await this.options.reserveRequest();
    const url = new URL(`/v2/vehiclepositions/${encodeURIComponent(gtfsTripId)}`, this.options.baseUrl);
    url.search = new URLSearchParams({ includeNotTracking: "false", includePositions: "false" }).toString();
    const response = await this.options.fetcher(url, {
      headers: { accept: "application/json", "X-Access-Token": this.apiKey,
        "user-agent": "TrainTracker/0.4 (+https://github.com/jaguirre2192)" },
      signal: AbortSignal.timeout(8_000),
    });
    if (response.status === 404) { await response.body?.cancel(); return null; }
    if (!response.ok) { await response.body?.cancel(); throw new Error(`Golemio position returned ${response.status}`); }
    const value = record(await boundedJSON(response)), properties = record(value?.properties);
    const trip = record(properties?.trip), gtfs = record(trip?.gtfs);
    const position = record(properties?.last_position), geometry = record(value?.geometry);
    // Keep only the small GPS identity envelope, even if the API accidentally
    // includes history or unrelated rich properties despite includePositions=false.
    return { type: value?.type, geometry: { type: geometry?.type, coordinates: geometry?.coordinates },
      properties: { trip: { start_timestamp: trip?.start_timestamp,
        gtfs: { route_type: gtfs?.route_type, trip_id: gtfs?.trip_id } },
      last_position: { bearing: position?.bearing, origin_timestamp: position?.origin_timestamp,
        tracking: position?.tracking, is_canceled: position?.is_canceled, state_position: position?.state_position } } };

  }
}
