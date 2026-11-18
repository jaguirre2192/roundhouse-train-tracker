import gtfsRealtime, { type transit_realtime } from "gtfs-realtime-bindings";
import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import { enturServiceJourneyId } from "./entur-service-identity.js";
import { cachedLoad, ExpiringCache } from "./expiring-cache.js";

function window(stops: StopSnapshot[]): [number, number] | null {
  const times = stops.flatMap(stop => [stop.scheduledArrival, stop.scheduledDeparture, stop.expectedArrival, stop.expectedDeparture])
    .map(value => Date.parse(value ?? "")).filter(Number.isFinite);
  return times.length === 0 ? null : [Math.min(...times), Math.max(...times)];
}
function stopId(stop: StopSnapshot): string | null {
  return stop.stationId.match(/(?:^|_)(NSR:(?:Quay|StopPlace):[A-Za-z0-9-]+)$/u)?.[1] ?? null;
}
function activeDuring(alert: transit_realtime.IAlert, span: [number, number], now: number): boolean {
  return (alert.activePeriod ?? []).some(period => {
    const start = Object.hasOwn(period, "start") ? Number(period.start) * 1_000 : Number.NEGATIVE_INFINITY;
    const end = Object.hasOwn(period, "end") ? Number(period.end) * 1_000 : Number.POSITIVE_INFINITY;
    return !Number.isNaN(start) && !Number.isNaN(end) && start < end
      && now >= start && now < end && span[0] < end && span[1] >= start;
  });
}

export function enturTripAlertIds(feed: transit_realtime.IFeedMessage, snapshot: TripSnapshot, now: number): string[] {
  const journey = enturServiceJourneyId(snapshot), date = snapshot.serviceDate.replaceAll("-", "");
  if (journey === null || !snapshot.stops.some(stop => stop.countryCode === "NO")) return [];
  const headerAge = now - Number(feed.header.timestamp) * 1_000;
  if (!Object.hasOwn(feed.header, "timestamp") || !Number.isFinite(headerAge)
    || headerAge > 300_000 || headerAge < -120_000) return [];
  return [...new Set((feed.entity ?? []).flatMap(entity => {
    const alert = entity.alert;
    if (entity.isDeleted === true || typeof entity.id !== "string" || entity.id.trim().length === 0 || alert == null) return [];
    const hasText = [alert.headerText, alert.descriptionText].some(value => value?.translation?.some(text =>
      typeof text.text === "string" && text.text.trim().length > 0));
    if (!hasText) return [];
    const matches = (alert.informedEntity ?? []).some(selector => {
      // All selector fields are conjunctive. Never promote a broad line/agency
      // notice, an undated daily journey or a stop hierarchy guessed by name.
      if (selector.trip?.tripId !== journey || selector.trip.startDate !== date
        || (selector.agencyId?.length ?? 0) > 0 || (selector.routeId?.length ?? 0) > 0
        || Object.hasOwn(selector, "routeType") || Object.hasOwn(selector, "directionId")) return false;
      if (selector.trip.routeId || selector.trip.startTime) return false;
      const selected = selector.stopId ? snapshot.stops.filter(stop => stopId(stop) === selector.stopId) : snapshot.stops;
      const span = window(selected);
      return span !== null && activeDuring(alert, span, now);
    });
    return matches ? [`entur:${entity.id}`] : [];
  }))];
}

async function boundedBytes(response: Response): Promise<Uint8Array> {
  const maximum = 2 * 1_024 * 1_024;
  if (Number(response.headers.get("content-length")) > maximum) {
    await response.body?.cancel(); throw new Error("Entur alerts exceed byte limit");
  }
  if (response.body === null) throw new Error("Entur alerts have no body");
  const reader = response.body.getReader(), chunks: Uint8Array[] = [];
  let length = 0;
  for (;;) {
    const { value, done } = await reader.read(); if (done) break;
    length += value.byteLength;
    if (length > maximum) { await reader.cancel(); throw new Error("Entur alerts exceed byte limit"); }
    chunks.push(value);
  }
  const bytes = new Uint8Array(length); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return bytes;
}

export class EnturTripAlerts {
  private readonly feeds = new ExpiringCache<Promise<transit_realtime.FeedMessage>>(1);
  constructor(private readonly feedUrl: string, private readonly fetcher: typeof fetch, private readonly now: () => Date) {}

  async tripAlertIds(snapshot: TripSnapshot): Promise<string[]> {
    if (enturServiceJourneyId(snapshot) === null || !snapshot.stops.some(stop => stop.countryCode === "NO")) return [];
    const feed = await cachedLoad(this.feeds, "all", this.now().getTime(), 20_000, async () => {
      const response = await this.fetcher(this.feedUrl, {
        headers: { accept: "application/x-protobuf", "et-client-name": "traintracker-app" }, signal: AbortSignal.timeout(8_000),
      });
      if (!response.ok) throw new Error(`Entur alerts returned ${response.status}`);
      return gtfsRealtime.transit_realtime.FeedMessage.decode(await boundedBytes(response));
    });
    return enturTripAlertIds(feed, snapshot, this.now().getTime());
  }
}
