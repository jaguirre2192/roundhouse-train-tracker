import { SwissStaticPlatforms, type SwissPlatformLookup } from "./swiss-static-platforms.js";
import { needsRealtimeUpdate } from "./realtime-stop-candidates.js";
import { transit_realtime } from "gtfs-realtime-bindings";
import type { CanonicalTripReference, StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";

const defaultFeedURL = "https://api.opentransportdata.swiss/la/gtfs-rt";

function timestamp(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  const seconds = Number(value);
  return Number.isFinite(seconds) && seconds > 0 ? new Date(seconds * 1_000).toISOString() : null;
}

function expectedTime(
  event: transit_realtime.TripUpdate.IStopTimeEvent | null | undefined,
  scheduled: string | null,
): string | null | undefined {
  const absolute = timestamp(event?.time);
  if (absolute !== null) return absolute;
  if (event?.delay === null || event?.delay === undefined || scheduled === null) return undefined;
  const scheduledTime = Date.parse(scheduled);
  const delay = Number(event.delay) * 1_000;
  return Number.isFinite(scheduledTime) && Number.isFinite(delay)
    ? new Date(scheduledTime + delay).toISOString()
    : undefined;
}

function embeddedTripId(snapshot: Pick<TripSnapshot, "nativeId">): string | null {
  const match = snapshot.nativeId.match(/(\.ojp-[^\s_]+)$/u);
  return match?.[1] ?? null;
}

function routeSignature(tripId: string | null | undefined): string | null {
  if (tripId === null || tripId === undefined) return null;
  const index = tripId.indexOf(".TA.");
  return index < 0 ? null : tripId.slice(0, index);
}

function nativeStart(snapshot: Pick<TripSnapshot, "nativeId">): { date: string; time: string } | null {
  const match = snapshot.nativeId.match(/^(\d{8})_(\d{2}:\d{2})_/u);
  return match?.[1] === undefined || match[2] === undefined ? null : { date: match[1], time: `${match[2]}:00` };
}

function stopBase(stopId: string): string | null {
  return stopId.match(/^(ch:\d+:sloid:\d+)(?=[:_]|$)/u)?.[1]
    ?? stopId.match(/^(\d{7})(?=[:_]|$)/u)?.[1] ?? null;
}

function snapshotStopId(stop: StopSnapshot): string {
  const native = stop.stationId.replace(/^eu:transitous:ch-opentransportdataswiss\d{2}_/u, "");
  return native.match(/(ch:\d+:sloid:[^\s]+)$/u)?.[1] ?? native;
}

function snapshotStopBases(snapshot: TripSnapshot): Set<string> {
  return new Set(snapshot.stops.flatMap((stop) => {
    const base = stopBase(snapshotStopId(stop));
    return base === null ? [] : [base];
  }));
}

function overlap(entity: transit_realtime.IFeedEntity, snapshot: TripSnapshot): number {
  const bases = snapshotStopBases(snapshot);
  return new Set((entity.tripUpdate?.stopTimeUpdate ?? []).flatMap((update) => {
    const base = stopBase(update.stopId ?? "");
    return base !== null && bases.has(base) ? [base] : [];
  })).size;
}

function matchingEntity(
  feed: transit_realtime.FeedMessage,
  snapshot: TripSnapshot,
): transit_realtime.IFeedEntity | null {
  const embedded = embeddedTripId(snapshot);
  const date = snapshot.serviceDate.replaceAll("-", "");
  const exact = feed.entity.filter((entity) => entity.tripUpdate?.trip.tripId === embedded
    && entity.tripUpdate?.trip.startDate === date);
  if (exact.length === 1) return exact[0]!;
  if (exact.length > 1) return null;
  const start = nativeStart(snapshot);
  const signature = routeSignature(embedded);
  if (start === null || signature === null || start.date !== date) return null;
  const candidates = feed.entity.filter((entity) => {
    const descriptor = entity.tripUpdate?.trip;
    return descriptor?.startDate === start.date
      && descriptor.startTime === start.time
      && routeSignature(descriptor.tripId) === signature;
  }).map((entity) => ({ entity, overlap: overlap(entity, snapshot) }))
    .filter((candidate) => candidate.overlap >= 2
      || candidate.entity.tripUpdate?.trip.scheduleRelationship
        === transit_realtime.TripDescriptor.ScheduleRelationship.CANCELED)
    .sort((left, right) => right.overlap - left.overlap);
  if (candidates.length === 0) return null;
  if (candidates.length > 1 && candidates[0]!.overlap === candidates[1]!.overlap) return null;
  return candidates[0]!.entity;
}

function matchingStop(
  snapshot: TripSnapshot,
  update: transit_realtime.TripUpdate.IStopTimeUpdate,
): StopSnapshot | null {
  const id = update.stopId ?? "";
  const exact = snapshot.stops.filter((stop) => stop.stationId === id || stop.stationId.endsWith(`_${id}`));
  if (exact.length === 1 && id.length > 0) return exact[0]!;
  const base = stopBase(id);
  if (base === null) return null;
  const candidates = snapshot.stops.filter((stop) =>
    stopBase(snapshotStopId(stop)) === base);
  return candidates.length === 1 ? candidates[0]! : null;
}

function platformFromStopId(stopId: string | null | undefined): string | null {
  // SLOID quay identifiers are not passenger-facing track numbers. Since June
  // 2026 ambiguous quays encode an explicit platform code in the _pf: suffix.
  // https://opentransportdata.swiss/en/cookbook/timetable-cookbook/gtfs/
  const explicit = stopId?.match(/_pf:([\p{Letter}\p{Number}./-]{1,20})$/u)?.[1];
  // Dots replace multiple possible special characters upstream. Decoding them
  // as slashes would invent a label; retain the baseline until a static lookup.
  if (explicit !== undefined) return explicit.includes(".") ? null : explicit;
  // Older Didok-based stop IDs included the literal platform as their last part.
  return stopId?.match(/^\d{7}:\d+:([\p{Letter}\p{Number}/-]{1,20})$/u)?.[1] ?? null;
}

export class SwissRealtimeOverlay implements PlatformRealtimeOverlay {
  readonly sourceName = "Swiss GTFS-RT";
  readonly supportedCountryCodes = new Set(["CH", "LI"]);
  private cachedFeed: { loadedAt: number; value: Promise<transit_realtime.FeedMessage> } | null = null;

  constructor(
    private readonly token: string,
    private readonly feedURL = defaultFeedURL,
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
    private readonly staticPlatforms: SwissPlatformLookup = new SwissStaticPlatforms(fetcher, now),
  ) {}

  async prefetch(reference: CanonicalTripReference): Promise<void> {
    if (reference.source !== "transitous" || !/_ch-opentransportdataswiss\d{2}_/u.test(reference.nativeId)) return;
    const embedded = embeddedTripId(reference), start = nativeStart(reference), date = reference.serviceDate.replaceAll("-", "");
    if (embedded === null || start?.date !== date) return;
    const feed = await this.feed();
    const unresolved = feed.entity.some((entity) => {
      const descriptor = entity.tripUpdate?.trip;
      return descriptor?.startDate === date && (descriptor.tripId === embedded
        || (descriptor.startTime === start.time && routeSignature(descriptor.tripId) === routeSignature(embedded)))
        && entity.tripUpdate?.stopTimeUpdate?.some((update) => platformFromStopId(update.stopId) === null);
    });
    if (unresolved) await this.staticPlatforms.load(feed.header.feedVersion ?? "", reference.serviceDate);
  }

  async platformUpdates(snapshot: TripSnapshot): Promise<PlatformObservation[]> {
    const feed = await this.feed();
    const entity = matchingEntity(feed, snapshot);
    const tripUpdate = entity?.tripUpdate;
    if (tripUpdate === null || tripUpdate === undefined) return [];
    const observedAt = timestamp(tripUpdate.timestamp) ?? timestamp(feed.header.timestamp) ?? this.now().toISOString();
    const tripCancelled = tripUpdate.trip.scheduleRelationship
      === transit_realtime.TripDescriptor.ScheduleRelationship.CANCELED
      || tripUpdate.trip.scheduleRelationship === transit_realtime.TripDescriptor.ScheduleRelationship.DELETED;
    const updates = tripUpdate.stopTimeUpdate ?? [];
    if (tripCancelled && updates.length === 0) {
      return snapshot.stops.filter((stop) => needsRealtimeUpdate(stop, snapshot) && this.supportedCountryCodes.has(stop.countryCode)).map((stop) => ({
        stopSequence: stop.sequence,
        stationId: stop.stationId,
        cancelled: true,
        observedAt,
        source: this.sourceName,
      }));
    }
    const needsStatic = updates.some((update) => {
      const stop = matchingStop(snapshot, update);
      return stop !== null && this.supportedCountryCodes.has(stop.countryCode) && needsRealtimeUpdate(stop, snapshot)
        && platformFromStopId(update.stopId) === null;
    });
    let timer: ReturnType<typeof setTimeout> | undefined;
    const staticIndex = needsStatic ? await Promise.race([
      this.staticPlatforms.load(feed.header.feedVersion ?? "", snapshot.serviceDate).catch(() => null),
      new Promise<null>((resolve) => { timer = setTimeout(() => resolve(null), 250); }),
    ]).finally(() => clearTimeout(timer)) : null;
    return updates.flatMap((update): PlatformObservation[] => {
      const stop = matchingStop(snapshot, update);
      if (stop === null || !this.supportedCountryCodes.has(stop.countryCode) || !needsRealtimeUpdate(stop, snapshot)) return [];
      const expectedPlatform = platformFromStopId(update.stopId) ?? staticIndex?.platforms.get(update.stopId ?? "") ?? null;
      const expectedArrival = expectedTime(update.arrival, stop.scheduledArrival);
      const expectedDeparture = expectedTime(update.departure, stop.scheduledDeparture);
      const cancelled = tripCancelled
        || update.scheduleRelationship === transit_realtime.TripUpdate.StopTimeUpdate.ScheduleRelationship.SKIPPED;
      if (expectedPlatform === null && expectedArrival === undefined && expectedDeparture === undefined && !cancelled) return [];
      return [{
        stopSequence: stop.sequence,
        stationId: stop.stationId,
        plannedPlatform: stop.plannedPlatform,
        expectedPlatform,
        expectedArrival,
        expectedDeparture,
        cancelled,
        observedAt,
        source: this.sourceName,
      }];
    });
  }

  private feed(): Promise<transit_realtime.FeedMessage> {
    const now = this.now().getTime();
    if (this.cachedFeed !== null && now - this.cachedFeed.loadedAt < 30_000) return this.cachedFeed.value;
    const value = this.fetcher(this.feedURL, {
      headers: {
        accept: "application/octet-stream",
        "accept-encoding": "br, gzip, deflate",
        authorization: `Bearer ${this.token}`,
        "user-agent": "TrainTracker/0.4 (+https://github.com/jaguirre2192)",
      },
      redirect: "follow",
      signal: AbortSignal.timeout(15_000),
    }).then(async (response) => {
      if (!response.ok) throw new Error(`Swiss GTFS-RT returned ${response.status}`);
      return transit_realtime.FeedMessage.decode(new Uint8Array(await response.arrayBuffer()));
    });
    this.cachedFeed = { loadedAt: now, value };
    return value;
  }
}
