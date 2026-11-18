import { needsRealtimeUpdate } from "./realtime-stop-candidates.js";
import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";
import {
  matchTranslinkNIJourney,
  selectTranslinkNIStation,
  translinkNIEnrichment,
  translinkNIStationSearchName,
  translinkNITrip,
  type TranslinkNIEnrichment,
} from "./translink-ni-api-matching.js";
import type {
  TranslinkNILocation,
  TranslinkNIStopFinderResponse,
  TranslinkNITripResponse,
} from "./translink-ni-api-models.js";

const defaultBaseURL = "https://opendata.translinkniplanner.co.uk/Ext_API";
const tripCacheMilliseconds = 120_000;

interface TripWindow {
  origin: StopSnapshot;
  destination: StopSnapshot;
  departure: string;
}

function windowFor(snapshot: TripSnapshot): TripWindow | null {
  const firstUpcoming = snapshot.stops.findIndex((stop) => needsRealtimeUpdate(stop, snapshot));
  if (firstUpcoming < 0 || snapshot.stops.length < 2) return null;
  const destinationIndex = snapshot.stops.length - 1;
  const originIndex = Math.min(firstUpcoming, destinationIndex - 1);
  const origin = snapshot.stops[originIndex]!;
  const destination = snapshot.stops[destinationIndex]!;
  const departure = origin.scheduledDeparture ?? origin.scheduledArrival;
  return departure === null ? null : { origin, destination, departure };
}

function londonDateTime(value: string): { date: string; time: string } {
  const requested = Date.parse(value) - 10 * 60_000;
  if (Number.isNaN(requested)) throw new Error("Translink NI trip has no valid scheduled time");
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/London",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(new Date(requested));
  const part = (type: Intl.DateTimeFormatPartTypes) =>
    parts.find((candidate) => candidate.type === type)?.value ?? "";
  return {
    date: `${part("year")}${part("month")}${part("day")}`,
    time: `${part("hour")}${part("minute")}`,
  };
}

export class TranslinkNIOpendataOverlay implements PlatformRealtimeOverlay {
  readonly sourceName = "Translink NI Opendata API";
  readonly supportedCountryCodes = new Set(["GB", "IE"]);
  private readonly stationCache = new Map<
    string,
    { loadedAt: number; value: Promise<TranslinkNILocation | null> }
  >();
  private readonly tripCache = new Map<
    string,
    { loadedAt: number; value: Promise<TranslinkNITripResponse> }
  >();
  private readonly enrichmentCache = new Map<
    string,
    { loadedAt: number; value: Promise<TranslinkNIEnrichment> }
  >();

  constructor(
    private readonly apiToken: string,
    private readonly baseURL = defaultBaseURL,
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
  ) {}

  async platformUpdates(snapshot: TripSnapshot): Promise<PlatformObservation[]> {
    return (await this.enrich(snapshot)).observations;
  }

  async tripAlertIds(snapshot: TripSnapshot): Promise<string[]> {
    return (await this.enrich(snapshot)).alertIds;
  }

  private enrich(snapshot: TripSnapshot): Promise<TranslinkNIEnrichment> {
    if (!translinkNITrip(snapshot)) return Promise.resolve({ observations: [], alertIds: [] });
    const cached = this.enrichmentCache.get(snapshot.id);
    const now = this.now().getTime();
    if (cached !== undefined && now - cached.loadedAt < 30_000) return cached.value;
    const value = this.loadEnrichment(snapshot);
    if (this.enrichmentCache.size >= 200) this.enrichmentCache.clear();
    this.enrichmentCache.set(snapshot.id, { loadedAt: now, value });
    return value;
  }

  private async loadEnrichment(snapshot: TripSnapshot): Promise<TranslinkNIEnrichment> {
    const window = windowFor(snapshot);
    if (window === null) return { observations: [], alertIds: [] };
    const [origin, destination] = await Promise.all([
      this.station(window.origin),
      this.station(window.destination),
    ]);
    if (origin === null || destination === null || origin.id === destination.id) {
      return { observations: [], alertIds: [] };
    }
    const response = await this.trip(origin.id, destination.id, window.departure);
    const match = matchTranslinkNIJourney(snapshot, window.origin, window.destination, response);
    return match === null
      ? { observations: [], alertIds: [] }
      : translinkNIEnrichment(snapshot, match, this.now().toISOString());
  }

  private station(stop: StopSnapshot): Promise<TranslinkNILocation | null> {
    const key = `${stop.stationId}:${stop.stationName}`;
    const now = this.now().getTime();
    const cached = this.stationCache.get(key);
    if (cached !== undefined && now - cached.loadedAt < 24 * 60 * 60_000) return cached.value;
    const value = this.json<TranslinkNIStopFinderResponse>("XML_STOPFINDER_REQUEST", {
      ext_macro: "sf",
      type_sf: "any",
      name_sf: translinkNIStationSearchName(stop.stationName),
    }).then((response) => selectTranslinkNIStation(stop, response.locations ?? []));
    if (this.stationCache.size >= 200) this.stationCache.clear();
    this.stationCache.set(key, { loadedAt: now, value });
    return value;
  }

  private trip(origin: string, destination: string, departure: string): Promise<TranslinkNITripResponse> {
    const input = londonDateTime(departure);
    const key = `${origin}:${destination}:${input.date}:${input.time}`;
    const now = this.now().getTime();
    const cached = this.tripCache.get(key);
    if (cached !== undefined && now - cached.loadedAt < tripCacheMilliseconds) return cached.value;
    const value = this.json<TranslinkNITripResponse>("XML_TRIP_REQUEST2", {
      ext_macro: "trip",
      type_origin: "any",
      name_origin: origin,
      type_destination: "any",
      name_destination: destination,
      itdDate: input.date,
      itdTime: input.time,
      calcOneDirection: "1",
      calcNumberOfTrips: "2",
      includedMeans: "0",
      genC: "0",
      useRealtime: "1",
    });
    if (this.tripCache.size >= 200) this.tripCache.clear();
    this.tripCache.set(key, { loadedAt: now, value });
    return value;
  }

  private async json<ResponseBody>(path: string, parameters: Record<string, string>): Promise<ResponseBody> {
    const url = new URL(path, `${this.baseURL.replace(/\/$/u, "")}/`);
    for (const [name, value] of Object.entries(parameters)) url.searchParams.set(name, value);
    const response = await this.fetcher(url, {
      headers: {
        accept: "application/json",
        "X-API-TOKEN": this.apiToken,
        "user-agent": "TrainTracker/1.1 (+https://github.com/jaguirre2192)",
      },
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) throw new Error(`Translink NI Opendata API returned ${response.status}`);
    return response.json() as Promise<ResponseBody>;
  }
}
