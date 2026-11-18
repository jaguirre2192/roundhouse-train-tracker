import { ExpiringCache } from "./expiring-cache.js";
import { sncfStationCodes, siriObservations } from "./sncf-siri.js";
import { needsRealtimeUpdate } from "./realtime-stop-candidates.js";
import { transit_realtime } from "gtfs-realtime-bindings";
import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";

const defaultFeedUrl = "https://proxy.transport.data.gouv.fr/resource/sncf-gtfs-rt-trip-updates";
const defaultAlertFeedUrl = "https://proxy.transport.data.gouv.fr/resource/sncf-gtfs-rt-service-alerts";
const defaultSiriFeedUrl = "https://proxy.transport.data.gouv.fr/resource/sncf-siri-lite-estimated-timetable";

// The SIRI-ET feed is large and slow; after a failure, skip it briefly instead of
// letting every trip in the next cycles wait on another 20 s timeout.
const siriFailureCooldownMilliseconds = 60_000;

let sharedSiriFeed: { loadedAt: number; url: string; value: string } | null = null;
let sharedSiriRequest: Promise<string> | null = null;
let sharedSiriFailedAt: number | null = null;

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

function matchingStop(
  snapshot: TripSnapshot,
  update: transit_realtime.TripUpdate.IStopTimeUpdate,
  codesForId: (id: string) => string[] = sncfStationCodes,
): StopSnapshot | undefined {
  const stopId = update.stopId?.trim();
  if (stopId !== undefined && stopId.length > 0) {
    const exact = snapshot.stops.find((stop) => stop.stationId.includes(stopId));
    if (exact !== undefined) return exact;
    const stopCodes = sncfStationCodes(stopId);
    const uic = snapshot.stops.find((stop) => {
      const stationCodes = codesForId(stop.stationId);
      return stationCodes.some((stationCode) => stopCodes.some((stopCode) =>
        stationCode.startsWith(stopCode) || stopCode.startsWith(stationCode)
      ));
    });
    if (uic !== undefined) return uic;
    if (stopCodes.length > 0) return undefined;
  }
  const sequence = Number(update.stopSequence ?? 0);
  return sequence > 0 ? snapshot.stops.find((stop) => stop.sequence === sequence) : undefined;
}

function serviceDateMatches(entity: transit_realtime.IFeedEntity, snapshot: TripSnapshot): boolean {
  const descriptor = entity.tripUpdate?.trip;
  const startDate = descriptor?.startDate?.trim();
  return startDate === undefined || startDate.length === 0
    || startDate === snapshot.serviceDate.replaceAll("-", "");
}

function nativeNumbers(id: string): string[] {
  return [...id.matchAll(/(?:OCE)?S[NA](\d{3,6})F/gu)]
    .flatMap((match) => match[1] === undefined ? [] : [match[1]]);
}

function productNumbers(snapshot: TripSnapshot): string[] {
  const values = nativeNumbers(snapshot.nativeId);
  if (/^(?:TGV|TER|INTERCIT[ÉE]S|OUIGO|INOUI|NOMAD)\b/iu.test(snapshot.product.trim())) {
    values.push(...(snapshot.product.match(/\d{3,6}/gu) ?? []));
  }
  const headsign = snapshot.headsign.trim();
  if (/^\d{3,6}$/u.test(headsign)) values.push(headsign);
  return [...new Set(values)];
}

function nearestTimeDifference(entity: transit_realtime.IFeedEntity, snapshot: TripSnapshot): number {
  const scheduled = snapshot.stops.flatMap((stop) => [stop.scheduledDeparture, stop.scheduledArrival])
    .find((value): value is string => value !== null);
  if (scheduled === undefined) return Number.POSITIVE_INFINITY;
  const update = entity.tripUpdate?.stopTimeUpdate?.[0];
  const observed = timestamp(update?.departure?.time) ?? timestamp(update?.arrival?.time);
  return observed === null ? Number.POSITIVE_INFINITY : Math.abs(Date.parse(observed) - Date.parse(scheduled));
}

function matchingEntity(
  feed: transit_realtime.FeedMessage,
  snapshot: TripSnapshot,
): transit_realtime.IFeedEntity | undefined {
  const dated = feed.entity.filter((entity) => serviceDateMatches(entity, snapshot));
  const exact = dated.find((entity) => {
    const tripId = entity.tripUpdate?.trip.tripId?.trim();
    return tripId !== undefined && tripId.length > 0 && snapshot.nativeId.includes(tripId);
  });
  if (exact !== undefined) return exact;

  const numbers = productNumbers(snapshot);
  if (numbers.length === 0) return undefined;
  const candidates = dated.filter((entity) => {
    const tripId = entity.tripUpdate?.trip.tripId ?? "";
    return numbers.some((number) => nativeNumbers(tripId).includes(number));
  }).map((entity) => ({ entity, difference: nearestTimeDifference(entity, snapshot) }))
    .filter((value) => value.difference <= 6 * 60 * 60_000)
    .sort((left, right) => left.difference - right.difference);
  if (candidates.length === 0) return undefined;
  if (candidates.length > 1 && candidates[0]!.difference === candidates[1]!.difference) return undefined;
  return candidates[0]!.entity;
}

export class SncfRealtimeOverlay implements PlatformRealtimeOverlay {
  readonly sourceName = "SNCF SIRI-ET";
  readonly supportedCountryCodes = new Set(["FR", "MC"]);
  private cachedFeed: { loadedAt: number; value: transit_realtime.FeedMessage } | null = null;
  private cachedAlertFeed: { loadedAt: number; value: transit_realtime.FeedMessage } | null = null;
  private cachedSiriFeed: { loadedAt: number; value: string } | null = null;
  private siriFailedAt: number | null = null;
  private feedRequest: Promise<transit_realtime.FeedMessage> | null = null;
  private alertFeedRequest: Promise<transit_realtime.FeedMessage> | null = null;
  private siriRequest: Promise<string> | null = null;
  private readonly stationCodeCache = new ExpiringCache<string[]>(1_000);

  constructor(
    private readonly feedUrl = defaultFeedUrl,
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
    private readonly alertFeedUrl: string | null = feedUrl === defaultFeedUrl ? defaultAlertFeedUrl : null,
    private readonly siriFeedUrl: string | null = feedUrl === defaultFeedUrl ? defaultSiriFeedUrl : null,
  ) {}

  // Start the large, coalesced feed while the base trip is loading. The existing
  // cache/cooldown still governs every call, including repeated base cache hits.
  async prefetch(reference: { nativeId: string }): Promise<void> {
    if (!/(?:^|_)fr-/u.test(reference.nativeId)) return;
    await Promise.allSettled([
      this.feed(),
      ...(this.siriFeedUrl === null ? [] : [this.siriFeed()]),
      ...(this.alertFeedUrl === null ? [] : [this.alertFeed()]),
    ]);
  }

  // Give GTFS timing its own enrichment deadline. A large or stalled SIRI feed
  // must not discard an already available delay or cancellation observation.
  readonly timingOverlay: PlatformRealtimeOverlay = {
    sourceName: "SNCF GTFS-RT",
    supportedCountryCodes: this.supportedCountryCodes,
    platformUpdates: (snapshot) => this.gtfsUpdates(snapshot),
  };

  async platformUpdates(snapshot: TripSnapshot): Promise<PlatformObservation[]> {
    try {
      return await this.siriUpdates(snapshot);
    } catch (error) {
      console.error("SNCF SIRI-ET subfeed failed", { error });
      return [];
    }
  }

  private async gtfsUpdates(snapshot: TripSnapshot): Promise<PlatformObservation[]> {
    const feed = await this.feed();
    const entity = matchingEntity(feed, snapshot);
    const tripUpdate = entity?.tripUpdate;
    if (tripUpdate === null || tripUpdate === undefined) return [];
    const observedAt = timestamp(tripUpdate.timestamp)
      ?? timestamp(feed.header.timestamp)
      ?? this.now().toISOString();
    const stopTimeUpdates = tripUpdate.stopTimeUpdate ?? [];
    const tripCancelled = tripUpdate.trip.scheduleRelationship
      === transit_realtime.TripDescriptor.ScheduleRelationship.CANCELED
      || tripUpdate.trip.scheduleRelationship === transit_realtime.TripDescriptor.ScheduleRelationship.DELETED;

    if (tripCancelled && stopTimeUpdates.length === 0) {
      return snapshot.stops.filter((stop) => needsRealtimeUpdate(stop, snapshot)).map((stop) => ({
        stopSequence: stop.sequence,
        stationId: stop.stationId,
        cancelled: true,
        observedAt,
        source: "SNCF GTFS-RT",
      }));
    }

    return stopTimeUpdates.flatMap((update): PlatformObservation[] => {
      const stop = matchingStop(snapshot, update, (id) =>
        this.stationCodeCache.get(id, this.now().getTime()) ?? sncfStationCodes(id));
      if (stop === undefined) return [];
      const cancelled = tripCancelled
        || update.scheduleRelationship === transit_realtime.TripUpdate.StopTimeUpdate.ScheduleRelationship.SKIPPED;
      const expectedArrival = expectedTime(update.arrival, stop.scheduledArrival);
      const expectedDeparture = expectedTime(update.departure, stop.scheduledDeparture);
      if (expectedArrival === undefined && expectedDeparture === undefined && !cancelled) return [];
      return [{
        stopSequence: stop.sequence,
        stationId: stop.stationId,
        expectedArrival,
        expectedDeparture,
        cancelled,
        observedAt,
        source: "SNCF GTFS-RT",
      }];
    });
  }

  private async siriUpdates(snapshot: TripSnapshot): Promise<PlatformObservation[]> {
    if (this.siriFeedUrl === null || productNumbers(snapshot).length === 0) return [];
    return siriObservations(await this.siriFeed(), snapshot, "SNCF SIRI-ET", productNumbers(snapshot), (stop, codes) => {
      if (codes.length > 0) this.stationCodeCache.set(stop.stationId, codes, this.now().getTime(), 24 * 60 * 60_000);
    });
  }

  async tripAlertIds(snapshot: TripSnapshot): Promise<string[]> {
    if (this.alertFeedUrl === null) return [];
    const numbers = productNumbers(snapshot);
    if (numbers.length === 0) return [];
    const feed = await this.alertFeed();
    const now = Math.floor(this.now().getTime() / 1_000);
    return feed.entity.flatMap((entity): string[] => {
      const alert = entity.alert;
      if (alert === null || alert === undefined) return [];
      const active = (alert.activePeriod ?? []).length === 0 || (alert.activePeriod ?? []).some((period) => {
        const start = period.start === null || period.start === undefined ? Number.NEGATIVE_INFINITY : Number(period.start);
        const end = period.end === null || period.end === undefined ? Number.POSITIVE_INFINITY : Number(period.end);
        return now >= start && now <= end;
      });
      if (!active) return [];
      const matches = (alert.informedEntity ?? []).some((selector) => {
        const tripId = selector.trip?.tripId ?? "";
        const alertNumbers = nativeNumbers(tripId);
        return numbers.some((number) => alertNumbers.includes(number));
      });
      return matches ? [`sncf:${entity.id}`] : [];
    });
  }

  private feed(): Promise<transit_realtime.FeedMessage> {
    return this.feedRequest ??= this.loadFeed().finally(() => { this.feedRequest = null; });
  }

  private async loadFeed(): Promise<transit_realtime.FeedMessage> {
    const now = this.now().getTime();
    if (this.cachedFeed !== null && now - this.cachedFeed.loadedAt < 30_000) return this.cachedFeed.value;
    const response = await this.fetcher(this.feedUrl, {
      headers: {
        accept: "application/x-protobuf",
        "user-agent": "TrainTracker/0.3 (+https://github.com/jaguirre2192)",
      },
      signal: AbortSignal.timeout(12_000),
    });
    if (!response.ok) throw new Error(`SNCF GTFS-RT returned ${response.status}`);
    const value = transit_realtime.FeedMessage.decode(new Uint8Array(await response.arrayBuffer()));
    this.cachedFeed = { loadedAt: this.now().getTime(), value };
    return value;
  }

  private alertFeed(): Promise<transit_realtime.FeedMessage> {
    return this.alertFeedRequest ??= this.loadAlertFeed().finally(() => { this.alertFeedRequest = null; });
  }

  private async loadAlertFeed(): Promise<transit_realtime.FeedMessage> {
    const now = this.now().getTime();
    if (this.cachedAlertFeed !== null && now - this.cachedAlertFeed.loadedAt < 60_000) {
      return this.cachedAlertFeed.value;
    }
    const response = await this.fetcher(this.alertFeedUrl!, {
      headers: {
        accept: "application/x-protobuf",
        "user-agent": "TrainTracker/0.4 (+https://github.com/jaguirre2192)",
      },
      signal: AbortSignal.timeout(12_000),
    });
    if (!response.ok) throw new Error(`SNCF GTFS-RT Service Alerts returned ${response.status}`);
    const value = transit_realtime.FeedMessage.decode(new Uint8Array(await response.arrayBuffer()));
    this.cachedAlertFeed = { loadedAt: this.now().getTime(), value };
    return value;
  }

  private siriFeed(): Promise<string> {
    return this.siriRequest ??= this.loadSiriFeed().finally(() => { this.siriRequest = null; });
  }

  private async loadSiriFeed(): Promise<string> {
    const now = this.now().getTime();
    if (this.siriFeedUrl === defaultSiriFeedUrl) {
      if (sharedSiriFeed !== null && sharedSiriFeed.url === this.siriFeedUrl
        && now - sharedSiriFeed.loadedAt < 90_000) return sharedSiriFeed.value;
      if (sharedSiriFailedAt !== null && now - sharedSiriFailedAt < siriFailureCooldownMilliseconds) {
        throw new Error("SNCF SIRI-ET is cooling down after a failure");
      }
      sharedSiriRequest ??= this.fetchSiriFeed().then((value) => {
        sharedSiriFailedAt = null;
        return value;
      }, (error: unknown) => {
        sharedSiriFailedAt = this.now().getTime();
        throw error;
      }).finally(() => { sharedSiriRequest = null; });
      const value = await sharedSiriRequest;
      sharedSiriFeed = { loadedAt: this.now().getTime(), url: this.siriFeedUrl, value };
      return value;
    }
    if (this.cachedSiriFeed !== null && now - this.cachedSiriFeed.loadedAt < 90_000) {
      return this.cachedSiriFeed.value;
    }
    if (this.siriFailedAt !== null && now - this.siriFailedAt < siriFailureCooldownMilliseconds) {
      throw new Error("SNCF SIRI-ET is cooling down after a failure");
    }
    try {
      const value = await this.fetchSiriFeed();
      this.cachedSiriFeed = { loadedAt: this.now().getTime(), value };
      this.siriFailedAt = null;
      return value;
    } catch (error) {
      this.siriFailedAt = this.now().getTime();
      throw error;
    }
  }

  private async fetchSiriFeed(): Promise<string> {
    const response = await this.fetcher(this.siriFeedUrl!, {
      headers: {
        accept: "application/xml, text/xml",
        "user-agent": "TrainTracker/0.4 (+https://github.com/jaguirre2192)",
      },
      signal: AbortSignal.timeout(20_000),
    });
    if (!response.ok) throw new Error(`SNCF SIRI-ET returned ${response.status}`);
    return response.text();
  }
}
