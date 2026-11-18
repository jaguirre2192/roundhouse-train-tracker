import { transit_realtime } from "gtfs-realtime-bindings";
import type { TripSnapshot } from "../domain/snapshot.js";
import type { GTFSRailIndex, GTFSRailTrip } from "./mainline-gtfs-index.js";

const feedURL = "https://mkuran.pl/gtfs/korail.pb", maximumBytes = 2 * 1024 * 1024;
/** This feed's stop-zero delay is synthetic. No stop, cancellation, passage or position overlay is produced. */
export class KorailRealtime {
  private cached: { at: number; value: Promise<transit_realtime.FeedMessage> } | null = null;
  constructor(private readonly fetcher: typeof fetch = (input,init) => fetch(input,init), private readonly now: () => Date = () => new Date()) {}
  async enrich(snapshot: TripSnapshot, index: GTFSRailIndex, trip: GTFSRailTrip): Promise<TripSnapshot> {
    if (index.country !== "KR" || snapshot.source !== "transitous" || !snapshot.nativeId.startsWith("ttgtfs:KR:trip:")) return snapshot;
    try {
      const feed = await this.feed(), published = Number(feed.header.timestamp) * 1000;
      const age = this.now().getTime() - published;
      if (!Number.isFinite(published) || published <= 0 || age < -120000 || age > 300000
        || feed.header.incrementality === transit_realtime.FeedHeader.Incrementality.DIFFERENTIAL) return snapshot;
      const matches = feed.entity.filter(e => !e.isDeleted && e.tripUpdate?.trip.tripId === trip.id);
      if (matches.length !== 1) return snapshot;
      const update = matches[0]!.tripUpdate!, descriptor = update.trip;
      if (!Object.hasOwn(update,"delay") || !Number.isSafeInteger(update.delay) || Math.abs(update.delay!) > 86400
        || (descriptor.scheduleRelationship !== undefined && descriptor.scheduleRelationship !== null
          && descriptor.scheduleRelationship !== transit_realtime.TripDescriptor.ScheduleRelationship.SCHEDULED)) return snapshot;
      const start = trip.calls[0]![3]!, end = trip.calls.at(-1)![2]!;
      // With no start_date, only a unique currently operating instance of this
      // exact static trip may receive the trip-level value. Midnight uses service day.
      const candidates = index.services[trip.service]!.filter(day => {
        if (descriptor.startDate && descriptor.startDate !== day.replaceAll("-","")) return false;
        const midnight = Date.parse(`${day}T00:00:00Z`) - 9 * 3600000;
        return published >= midnight + start * 1000 - 300000 && published <= midnight + end * 1000 + 7200000;
      });
      if (candidates.length !== 1 || candidates[0] !== snapshot.serviceDate) return snapshot;
      // The synthetic stopTimeUpdate and undated vehicle points are intentionally
      // unused. Feed publication is provenance for this value, not a point clock.
      return { ...snapshot, tripLevelDelay: { seconds: update.delay!, scope: "whole-trip",
        feedPublishedAt: new Date(published).toISOString(), source: "mkuran.pl Korail GTFS-RT" } };
    } catch { return snapshot; }
  }
  private feed(): Promise<transit_realtime.FeedMessage> {
    const at = this.now().getTime();
    if (this.cached && at - this.cached.at >= 0 && at - this.cached.at < 30000) return this.cached.value;
    const value = this.load(); this.cached = { at, value }; return value;
  }
  private async load(): Promise<transit_realtime.FeedMessage> {
    const response = await this.fetcher(feedURL,{ signal: AbortSignal.timeout(12000),
      headers: { accept: "application/x-protobuf", "user-agent": "TrainTrackerWatcher/1.0" } });
    if (!response.ok || !response.body || Number(response.headers.get("content-length")) > maximumBytes) {
      await response.body?.cancel(); throw new Error("Korail realtime unavailable");
    }
    const reader = response.body.getReader(), chunks: Uint8Array[] = []; let length = 0;
    try {
      for (;;) {
        const {value,done} = await reader.read(); if (done) break;
        length += value.length; if (length > maximumBytes) throw new Error("Korail realtime exceeds byte limit");
        chunks.push(value);
      }
    } finally { await reader.cancel().catch(()=>undefined); reader.releaseLock(); }
    const bytes = new Uint8Array(length); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk,offset); offset += chunk.length; }
    return transit_realtime.FeedMessage.decode(bytes);
  }
}
