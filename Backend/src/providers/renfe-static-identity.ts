import type { TripSnapshot } from "../domain/snapshot.js";
import type { RenfeTripDescriptor } from "./renfe-service-identity.js";
import { loadRenfeStaticIndex, type RenfeStaticIndex, type RenfeStaticLoadOptions } from "./renfe-static-loader.js";

export interface VerifiedRenfeService {
  tripId: string;
  serviceDate: string;
  startDate: string;
  routeId: string;
  matchedStops: number;
  staticFetchedAt: string;
}

const cacheDurationMs = 24 * 60 * 60_000;
const dateFormatter = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Europe/Madrid", year: "numeric", month: "2-digit", day: "2-digit",
  hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
});

function offsetAt(epoch: number): number {
  const parts = dateFormatter.formatToParts(epoch);
  const value = (name: string) => Number(parts.find((part) => part.type === name)?.value);
  return Date.UTC(value("year"), value("month") - 1, value("day"), value("hour"), value("minute"), value("second")) - epoch;
}

/** GTFS noon-minus-12h anchor. Transition-day/overnight offset changes fail closed. */
function serviceAnchor(day: string, maxSeconds: number): number | null {
  if (!/^\d{4}-\d{2}-\d{2}$/u.test(day)) return null;
  const utcNoon = Date.parse(`${day}T12:00:00Z`);
  if (!Number.isFinite(utcNoon) || new Date(utcNoon).toISOString().slice(0, 10) !== day) return null;
  const offset = offsetAt(utcNoon), noon = utcNoon - offset, anchor = noon - 12 * 3600_000;
  if ([anchor, noon, anchor + maxSeconds * 1000].some((time) => offsetAt(time) !== offset)) return null;
  return anchor;
}

function active(index: RenfeStaticIndex, service: string, day: string): boolean {
  const date = day.replaceAll("-", ""), exception = index.exceptions.get(service)?.get(date);
  if (exception !== undefined) return exception;
  const calendar = index.calendars.get(service), weekday = new Date(`${day}T12:00:00Z`).getUTCDay();
  return calendar !== undefined && calendar.start <= date && date <= calendar.end
    && (calendar.weekdays & (1 << weekday)) !== 0;
}

function identity(snapshot: TripSnapshot, trip: RenfeTripDescriptor): boolean {
  const match = /^(\d{8})_[^_]+_es-RENFE-Larga-Distancia-y-AVE_(\d{5})(\d{1,2})\d{4}-\d{2}-\d{2}$/u.exec(snapshot.nativeId);
  const candidate = /^(\d{5})(\d{1,2})\d{4}-\d{2}-\d{2}$/u.exec(trip.tripId);
  const date = snapshot.serviceDate.replaceAll("-", "");
  return snapshot.source === "transitous" && match !== null && candidate !== null
    && match[1] === date && match[2] === candidate[1] && match[3] === candidate[2]
    && (trip.startDate == null || (/^(?:\d{8}|\d{4}-\d{2}-\d{2})$/u.test(trip.startDate)
      && trip.startDate.replaceAll("-", "") === date));
}

function fullRouteMatches(index: RenfeStaticIndex, snapshot: TripSnapshot, tripId: string): boolean {
  const calls = index.calls.get(tripId);
  if (calls === undefined || calls.length < 2 || calls.length !== snapshot.stops.length) return false;
  const maxSeconds = Math.max(...calls.flatMap((call) => [call.arrival ?? 0, call.departure ?? 0]));
  const anchor = serviceAnchor(snapshot.serviceDate, maxSeconds);
  if (anchor === null) return false;
  const timedStations = new Set<string>();
  for (let i = 0; i < calls.length; i += 1) {
    const call = calls[i]!, stop = snapshot.stops[i]!;
    const station = /^eu:transitous:es-RENFE-Larga-Distancia-y-AVE_(.+)$/u.exec(stop.stationId)?.[1];
    if (station !== call.stationId) return false;
    if (!Number.isSafeInteger(stop.sequence) || (i > 0 && stop.sequence <= snapshot.stops[i - 1]!.sequence)) return false;
    let timed = false;
    for (const [scheduled, seconds, endpointMissingAllowed] of [
      [stop.scheduledArrival, call.arrival, i === 0],
      [stop.scheduledDeparture, call.departure, i === calls.length - 1],
    ] as const) {
      if (scheduled === null) { if (seconds !== null && !endpointMissingAllowed) return false; continue; }
      if (seconds === null || Date.parse(scheduled) !== anchor + seconds * 1000) return false;
      timed = true;
    }
    if (timed) timedStations.add(call.stationId);
  }
  return timedStations.size >= 2;
}

/** Verifies the scheduled run, not the age or provenance of any realtime observation. */
export class RenfeStaticIdentityVerifier {
  private cache: { index: RenfeStaticIndex; loadedAt: number } | null = null;
  private pending: Promise<void> | null = null;
  private retryAt = 0;

  constructor(
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
    private readonly options: RenfeStaticLoadOptions = {},
  ) {}

  async verify(snapshot: TripSnapshot, descriptor: RenfeTripDescriptor): Promise<VerifiedRenfeService | null> {
    if (!identity(snapshot, descriptor)) return null;
    await this.refresh();
    const cache = this.cache, now = this.now().getTime();
    if (cache === null || now < cache.loadedAt || now - cache.loadedAt >= cacheDurationMs) return null;
    const trip = cache.index.trips.get(descriptor.tripId);
    if (trip === undefined || !active(cache.index, trip.serviceId, snapshot.serviceDate)
      || !fullRouteMatches(cache.index, snapshot, descriptor.tripId)) return null;
    return {
      tripId: descriptor.tripId, serviceDate: snapshot.serviceDate, startDate: snapshot.serviceDate.replaceAll("-", ""),
      routeId: trip.routeId, matchedStops: snapshot.stops.length, staticFetchedAt: new Date(cache.loadedAt).toISOString(),
    };
  }

  private async refresh(): Promise<void> {
    const now = this.now().getTime();
    if (this.cache !== null && now >= this.cache.loadedAt && now - this.cache.loadedAt < cacheDurationMs) return;
    if (this.pending !== null) return this.pending;
    if (now < this.retryAt) return;
    this.pending = (async () => {
      try {
        const index = await loadRenfeStaticIndex(this.fetcher, this.options);
        this.cache = { index, loadedAt: this.now().getTime() };
        this.retryAt = 0;
      } catch {
        this.cache = null;
        this.retryAt = this.now().getTime() + 30_000;
      }
    })();
    try { await this.pending; } finally { this.pending = null; }
  }
}
