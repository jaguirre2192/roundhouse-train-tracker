import { realtimeCandidateStops } from "./realtime-stop-candidates.js";
import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import { cachedLoad, ExpiringCache } from "./expiring-cache.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";

const defaultBaseURL = "https://tiger-api-portal.worldline.global";

interface NIRLocation {
  TIPLOC: string;
  CRS: string;
  Name: string;
  TOC?: string[];
}

interface NIRCallingPoint {
  Name?: string;
  TIPLOC?: string;
  CRS?: string;
  STA?: string;
  STD?: string;
  ETA?: string;
  ETD?: string;
  ArrTimestamp?: string;
  DepTimestamp?: string;
  ExpectedArrTimestamp?: string;
  ExpectedDepTimestamp?: string;
  ArrStatus?: string;
  DepStatus?: string;
}

interface NIRSections<T> {
  Front?: T | T[] | null;
  Middle?: T | T[] | null;
  Rear?: T | T[] | null;
}

interface NIRService extends NIRCallingPoint {
  UID: string;
  Headcode?: string;
  Location?: string;
  Type?: string;
  ATOCCode?: string;
  ATOCDesc?: string;
  Category?: string;
  Platform?: string;
  ProcessedTimestamp?: string;
  SentTimestamp?: string;
  PlatformChanged?: boolean;
  Origins?: NIRSections<NIRCallingPoint>;
  Destinations?: NIRSections<NIRCallingPoint>;
  CallingPoints?: NIRSections<NIRCallingPoint>;
  Incident?: unknown;
  Comments?: unknown;
  ServiceUpdate?: unknown;
}

interface NIRBoard {
  TIPLOC?: string;
  CRS?: string;
  Name?: string;
  services?: NIRService[];
  timestamp?: string;
  incidentSummary?: unknown;
  specialNotice?: unknown;
  specialNoticeType?: unknown;
}

interface MatchedBoard {
  stop: StopSnapshot;
  station: NIRLocation;
  board: NIRBoard;
  service: NIRService;
}

interface EnrichmentResult {
  observations: PlatformObservation[];
  alertIds: string[];
}

function normalized(value: string): string {
  const plain = value.normalize("NFKD")
    .replace(/\p{Diacritic}/gu, "")
    .replace(/\b(?:railway|station|stn)\b/giu, " ")
    .replace(/[^\p{Letter}\p{Number}]+/gu, " ")
    .trim()
    .toLowerCase();
  if (["grand central", "belfast great central", "belfast great victoria street"].includes(plain)) {
    return "belfast grand central";
  }
  if (["yorkgate", "york street"].includes(plain)) return "york street";
  if (plain.includes("derry") && plain.includes("londonderry")) return "londonderry";
  return plain;
}

function nameMatches(left: string, right: string): boolean {
  const first = normalized(left);
  const second = normalized(right);
  if (first.length === 0 || second.length === 0) return false;
  if (first === second) return true;
  const shorter = first.length < second.length ? first : second;
  const longer = first.length < second.length ? second : first;
  return shorter.length >= 5 && longer.includes(shorter);
}

function values<T>(sections: NIRSections<T> | null | undefined): T[] {
  if (sections === null || sections === undefined) return [];
  return [sections.Front, sections.Middle, sections.Rear].flatMap((section) => {
    if (section === null || section === undefined) return [];
    return Array.isArray(section) ? section : [section];
  });
}

function stationForStop(stop: StopSnapshot, stations: NIRLocation[]): NIRLocation | null {
  const matches = stations.filter((station) => nameMatches(station.Name, stop.stationName));
  return matches.length === 1 ? matches[0]! : null;
}

function pointMatchesStation(point: NIRCallingPoint, station: NIRLocation): boolean {
  return point.TIPLOC === station.TIPLOC
    || (point.CRS !== undefined && point.CRS === station.CRS)
    || (point.Name !== undefined && nameMatches(point.Name, station.Name));
}

function servicePoints(service: NIRService): NIRCallingPoint[] {
  return [
    ...values(service.Origins),
    ...values(service.CallingPoints),
    ...values(service.Destinations),
  ];
}

function timestamp(value: string | null | undefined): number | null {
  if (value === null || value === undefined || value.trim().length === 0) return null;
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? null : parsed;
}

function iso(value: string | null | undefined): string | null {
  const parsed = timestamp(value);
  return parsed === null ? null : new Date(parsed).toISOString();
}

function scheduledTimes(service: NIRService, station: NIRLocation): number[] {
  const direct = [service.DepTimestamp, service.ArrTimestamp];
  const points = servicePoints(service)
    .filter((point) => pointMatchesStation(point, station))
    .flatMap((point) => [point.DepTimestamp, point.ArrTimestamp]);
  return [...direct, ...points].flatMap((value) => {
    const parsed = timestamp(value);
    return parsed === null ? [] : [parsed];
  });
}

function destinationScore(snapshot: TripSnapshot, service: NIRService): number {
  const destinations = values(service.Destinations).flatMap((point) => point.Name === undefined ? [] : [point.Name]);
  const expected = [snapshot.headsign, snapshot.stops.at(-1)?.stationName]
    .filter((value): value is string => value !== undefined && value.trim().length > 0);
  return destinations.some((destination) => expected.some((name) => nameMatches(destination, name))) ? 20 : 0;
}

function originScore(snapshot: TripSnapshot, service: NIRService): number {
  const origin = snapshot.stops[0]?.stationName;
  if (origin === undefined) return 0;
  return values(service.Origins).some((point) => point.Name !== undefined && nameMatches(point.Name, origin)) ? 10 : 0;
}

function matchingService(
  snapshot: TripSnapshot,
  stop: StopSnapshot,
  station: NIRLocation,
  services: NIRService[],
): NIRService | null {
  const scheduled = [stop.scheduledDeparture, stop.scheduledArrival].flatMap((value) => {
    const parsed = timestamp(value);
    return parsed === null ? [] : [parsed];
  });
  if (scheduled.length === 0) return null;
  const candidates = services.filter((service) => service.ATOCCode === undefined
    || service.ATOCCode.toUpperCase() === "NI"
    || normalized(service.ATOCDesc ?? "").includes("translink"))
    .map((service) => {
      const times = scheduledTimes(service, station);
      const difference = Math.min(...times.flatMap((actual) => scheduled.map((planned) => Math.abs(actual - planned))));
      return { service, difference, score: destinationScore(snapshot, service) + originScore(snapshot, service) };
    })
    .filter((candidate) => Number.isFinite(candidate.difference)
      && candidate.difference <= 10 * 60_000 && candidate.score >= 20)
    .sort((left, right) => right.score - left.score || left.difference - right.difference);
  if (candidates.length === 0) return null;
  if (candidates.length > 1 && candidates[0]!.score === candidates[1]!.score
    && candidates[0]!.difference === candidates[1]!.difference
    && candidates[0]!.service.UID !== candidates[1]!.service.UID) return null;
  return candidates[0]!.service;
}

function platform(value: string | null | undefined): string | null {
  const result = value?.trim();
  return result === undefined || result.length === 0 || result === "-" ? null : result;
}

function cancelled(...statuses: Array<string | null | undefined>): boolean {
  return statuses.some((status) => normalized(status ?? "").includes("cancelled"));
}

function hasStatus(point: NIRCallingPoint): boolean {
  return [point.ArrStatus, point.DepStatus].some((status) => status !== undefined && status.trim().length > 0);
}

function observedAt(board: NIRBoard, service: NIRService, fallback: Date): string {
  const candidates = [board.timestamp, service.ProcessedTimestamp, service.SentTimestamp]
    .flatMap((value) => {
      const parsed = timestamp(value);
      return parsed === null ? [] : [parsed];
    });
  return new Date(candidates.length === 0 ? fallback.getTime() : Math.max(...candidates)).toISOString();
}

function fnv1a(value: string): string {
  let hash = 0x811c9dc5;
  for (const character of value) {
    hash ^= character.codePointAt(0) ?? 0;
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}

function messageStrings(value: unknown, depth = 0): string[] {
  if (depth > 3 || value === null || value === undefined) return [];
  if (typeof value === "string") return value.trim().length === 0 ? [] : [value.trim()];
  if (Array.isArray(value)) return value.flatMap((item) => messageStrings(item, depth + 1));
  if (typeof value === "object") return Object.values(value).flatMap((item) => messageStrings(item, depth + 1));
  return [];
}

function alertIds(board: NIRBoard, service: NIRService): string[] {
  const ignored = new Set(["none", "null", "no incident", "no incidents", "normal service"]);
  const messages = [board.incidentSummary, board.specialNotice, service.Incident, service.Comments, service.ServiceUpdate]
    .flatMap((value) => messageStrings(value))
    .filter((message) => !ignored.has(normalized(message)));
  return [...new Set(messages.map((message) => `translink-nir:${service.UID}:${fnv1a(normalized(message))}`))];
}

function isNIRTrip(snapshot: TripSnapshot): boolean {
  const identity = normalized(`${snapshot.nativeId} ${snapshot.operatorName} ${snapshot.product}`);
  return identity.includes("gb northern ireland")
    || identity.includes("translink")
    || identity.includes("northern ireland rail")
    || identity.includes("enterprise");
}

export class TranslinkNIRRealtimeOverlay implements PlatformRealtimeOverlay {
  readonly sourceName = "Translink NIR Realtime (Open Data NI)";
  readonly supportedCountryCodes = new Set(["GB", "IE"]);
  private stationsCache: { loadedAt: number; value: Promise<NIRLocation[]> } | null = null;
  private readonly boardCache = new ExpiringCache<Promise<NIRBoard>>(200);
  private readonly enrichmentCache = new ExpiringCache<Promise<EnrichmentResult>>(500);

  constructor(
    private readonly apiKey: string,
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

  private enrich(snapshot: TripSnapshot): Promise<EnrichmentResult> {
    if (!isNIRTrip(snapshot)) return Promise.resolve({ observations: [], alertIds: [] });
    const now = this.now().getTime();
    return cachedLoad(this.enrichmentCache, snapshot.id, now, 30_000, () => this.loadEnrichment(snapshot));
  }

  private async loadEnrichment(snapshot: TripSnapshot): Promise<EnrichmentResult> {
    const stations = await this.stations();
    const stops = realtimeCandidateStops(snapshot, () => true, 3)
      .map((stop) => ({ stop, station: stationForStop(stop, stations) }))
      .filter((candidate): candidate is { stop: StopSnapshot; station: NIRLocation } => candidate.station !== null);
    const anchors = [...new Map(stops.map((candidate) => [candidate.station.TIPLOC, candidate])).values()];
    const matches = (await Promise.all(anchors.map(async ({ stop, station }): Promise<MatchedBoard | null> => {
      const board = await this.board(station.TIPLOC);
      const service = matchingService(snapshot, stop, station, board.services ?? []);
      return service === null ? null : { stop, station, board, service };
    }))).filter((value): value is MatchedBoard => value !== null);
    if (matches.length === 0) return { observations: [], alertIds: [] };

    const primaryUID = [...new Map(matches.map((match) => [match.service.UID, 0])).keys()]
      .map((uid) => ({ uid, count: matches.filter((match) => match.service.UID === uid).length }))
      .sort((left, right) => right.count - left.count)[0]!.uid;
    const consistent = matches.filter((match) => match.service.UID === primaryUID);
    const observations = new Map<number, PlatformObservation>();
    const alerts: string[] = [];

    const merge = (stop: StopSnapshot, patch: Partial<PlatformObservation>, seenAt: string) => {
      const previous = observations.get(stop.sequence);
      observations.set(stop.sequence, {
        stopSequence: stop.sequence,
        stationId: stop.stationId,
        observedAt: seenAt,
        source: this.sourceName,
        ...previous,
        ...patch,
      });
    };

    for (const match of consistent) {
      const seenAt = observedAt(match.board, match.service, this.now());
      const wholeServiceCancelled = cancelled(match.service.ArrStatus, match.service.DepStatus);
      const atServiceLocation = match.service.Location === undefined
        || match.service.Location === match.station.TIPLOC;
      const currentPlatform = atServiceLocation ? platform(match.service.Platform) : null;
      const currentPatch: Partial<PlatformObservation> = {};
      const currentArrival = atServiceLocation ? iso(match.service.ExpectedArrTimestamp) : null;
      const currentDeparture = atServiceLocation ? iso(match.service.ExpectedDepTimestamp) : null;
      if (currentPlatform !== null) currentPatch.expectedPlatform = currentPlatform;
      if (currentArrival !== null) currentPatch.expectedArrival = currentArrival;
      if (currentDeparture !== null) currentPatch.expectedDeparture = currentDeparture;
      if (wholeServiceCancelled || hasStatus(match.service)) currentPatch.cancelled = wholeServiceCancelled;
      merge(match.stop, currentPatch, seenAt);

      for (const { stop, station } of stops) {
        const point = servicePoints(match.service).find((candidate) => pointMatchesStation(candidate, station));
        if (point === undefined) continue;
        const pointPatch: Partial<PlatformObservation> = {};
        const pointArrival = iso(point.ExpectedArrTimestamp);
        const pointDeparture = iso(point.ExpectedDepTimestamp);
        if (pointArrival !== null) pointPatch.expectedArrival = pointArrival;
        if (pointDeparture !== null) pointPatch.expectedDeparture = pointDeparture;
        if (wholeServiceCancelled || hasStatus(point)) {
          pointPatch.cancelled = wholeServiceCancelled || cancelled(point.ArrStatus, point.DepStatus);
        }
        merge(stop, pointPatch, seenAt);
      }
      if (wholeServiceCancelled) {
        for (const { stop } of stops) merge(stop, { cancelled: true }, seenAt);
      }
      alerts.push(...alertIds(match.board, match.service));
    }
    return { observations: [...observations.values()], alertIds: [...new Set(alerts)] };
  }

  private stations(): Promise<NIRLocation[]> {
    const now = this.now().getTime();
    if (this.stationsCache !== null && now - this.stationsCache.loadedAt < 24 * 60 * 60_000) {
      return this.stationsCache.value;
    }
    const value = this.json<NIRLocation[]>("locations")
      .then((locations) => locations.filter((location) => location.TOC?.includes("NIR") === true));
    this.stationsCache = { loadedAt: now, value };
    return value;
  }

  private board(tiploc: string): Promise<NIRBoard> {
    const now = this.now().getTime();
    return cachedLoad(this.boardCache, tiploc, now, 120_000, () =>
      this.json<NIRBoard>(`services/${encodeURIComponent(tiploc)}`));
  }

  private async json<ResponseBody>(path: string): Promise<ResponseBody> {
    const response = await this.fetcher(new URL(path, `${this.baseURL}/`), {
      headers: {
        accept: "application/json",
        "x-api-key": this.apiKey,
        "user-agent": "TrainTracker/0.4 (+https://github.com/jaguirre2192)",
      },
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) throw new Error(`Translink NIR realtime returned ${response.status}`);
    return response.json() as Promise<ResponseBody>;
  }
}
