import { needsRealtimeUpdate, realtimeCandidateStops } from "./realtime-stop-candidates.js";
import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";

const defaultBaseURL = "https://realtime-api.trafiklab.se/v1";
const stockholmTime = new Intl.DateTimeFormat("sv-SE", {
  timeZone: "Europe/Stockholm",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hourCycle: "h23",
});

interface TrafiklabPlatform {
  designation?: string | null;
}

interface TrafiklabAlert {
  type?: string | null;
  title?: string | null;
  text?: string | null;
}

interface TrafiklabCall {
  scheduled?: string | null;
  realtime?: string | null;
  delay?: number | null;
  canceled?: boolean | null;
  scheduledDeparture?: string | null;
  realtimeDeparture?: string | null;
  departureDelay?: number | null;
  departureCanceled?: boolean | null;
  scheduledArrival?: string | null;
  realtimeArrival?: string | null;
  arrivalDelay?: number | null;
  arrivalCanceled?: boolean | null;
  route?: {
    name?: string | null;
    designation?: string | null;
    transport_mode?: string | null;
    direction?: string | null;
  } | null;
  trip?: {
    trip_id?: string | null;
    start_date?: string | null;
    technical_number?: number | string | null;
  } | null;
  stop?: {
    area_id?: string | null;
    name?: string | null;
  } | null;
  scheduled_platform?: TrafiklabPlatform | null;
  realtime_platform?: TrafiklabPlatform | null;
  alerts?: TrafiklabAlert[] | null;
  is_realtime?: boolean | null;
}

interface TrafiklabBoardResponse {
  timestamp?: string | null;
  departures?: TrafiklabCall[] | null;
  arrivals?: TrafiklabCall[] | null;
}

interface TrafiklabTripResponse {
  calls?: TrafiklabCall[] | null;
}

interface Anchor {
  stop: StopSnapshot;
  areaId: string;
  direction: "departures" | "arrivals";
  scheduled: string;
  localScheduled: string;
}

interface ResolvedTimetableTrip {
  anchor: Anchor;
  boardCall: TrafiklabCall;
  calls: TrafiklabCall[];
  observedAt: string;
  tripId: string;
}

function normalized(value: string | null | undefined): string {
  return (value ?? "")
    .normalize("NFKD")
    .replace(/\p{Diacritic}/gu, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/gu, " ")
    .trim();
}

function designation(value: TrafiklabPlatform | null | undefined): string | null {
  const result = value?.designation?.trim();
  return result === undefined || result.length === 0 ? null : result;
}

function areaId(stop: StopSnapshot): string | null {
  const match = stop.stationId.match(/se-Trafiklab_(\d{6,12})(?:$|[^0-9])/u);
  return match?.[1] ?? null;
}

function stockholmLocal(iso: string): string | null {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return null;
  const parts = Object.fromEntries(stockholmTime.formatToParts(date).map((part) => [part.type, part.value]));
  return `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}:${parts.second}`;
}

function minute(value: string | null | undefined): string {
  return (value ?? "").slice(0, 16);
}

function numericTokens(value: string): Set<string> {
  return new Set(value.match(/\d+/gu) ?? []);
}

function productScore(snapshot: TripSnapshot, call: TrafiklabCall): number {
  const product = normalized(snapshot.product);
  const routeName = normalized(call.route?.name);
  const routeDesignation = normalized(call.route?.designation);
  const technicalNumber = normalized(String(call.trip?.technical_number ?? ""));
  if (product.length > 0 && product === technicalNumber) return 50;
  if (product.length > 0 && product === routeDesignation) return 50;
  if (routeDesignation.length > 0 && numericTokens(snapshot.product).has(routeDesignation)) return 50;
  if (product.length > 2 && routeName.length > 2
    && (product.includes(routeName) || routeName.includes(product))) return 25;
  return 0;
}

function directionScore(snapshot: TripSnapshot, call: TrafiklabCall): number {
  const expected = [snapshot.headsign, snapshot.stops.at(-1)?.stationName].map(normalized).filter(Boolean);
  const actual = normalized(call.route?.direction);
  if (actual.length === 0) return 0;
  return expected.some((value) => value === actual) ? 20
    : expected.some((value) => value.length > 3 && (value.includes(actual) || actual.includes(value))) ? 10
      : 0;
}

function selectAnchors(snapshot: TripSnapshot): Anchor[] {
  if (!snapshot.nativeId.includes("_se-Trafiklab_")) return [];
  const anchors: Anchor[] = [];
  for (const stop of realtimeCandidateStops(snapshot, (stop) => stop.countryCode.toUpperCase() === "SE", 1)) {
    const id = areaId(stop);
    const scheduled = stop.scheduledDeparture ?? stop.scheduledArrival;
    const localScheduled = scheduled === null ? null : stockholmLocal(scheduled);
    if (id === null || scheduled === null || localScheduled === null) continue;
    anchors.push({
      stop,
      areaId: id,
      direction: stop.scheduledDeparture === null ? "arrivals" : "departures",
      scheduled,
      localScheduled,
    });
  }
  return anchors;
}

function hash(value: string): string {
  let result = 2_166_136_261;
  for (const character of value) {
    result ^= character.codePointAt(0) ?? 0;
    result = Math.imul(result, 16_777_619);
  }
  return (result >>> 0).toString(16).padStart(8, "0");
}

function alertIds(value: ResolvedTimetableTrip): string[] {
  const alerts = [
    ...(value.boardCall.alerts ?? []),
    ...value.calls.flatMap((call) => call.alerts ?? []),
  ];
  return [...new Set(alerts.flatMap((alert) => {
    const signature = normalized(`${alert.type ?? ""} ${alert.title ?? ""} ${alert.text ?? ""}`);
    return signature.length === 0 ? [] : [`trafiklab-se-api:${value.tripId}:${hash(signature)}`];
  }))];
}

function expectedTime(
  scheduled: string | null,
  realtime: string | null | undefined,
  delay: number | null | undefined,
): string | undefined {
  if (scheduled === null || !realtime?.trim() || delay === null || delay === undefined) {
    return undefined;
  }
  const seconds = Number(delay);
  if (!Number.isInteger(seconds) || Math.abs(seconds) > 86_400) return undefined;
  const value = new Date(Date.parse(scheduled) + seconds * 1_000);
  return Number.isFinite(value.getTime()) ? value.toISOString() : undefined;
}

export class TrafiklabSwedenTimetableOverlay implements PlatformRealtimeOverlay {
  readonly sourceName = "Trafiklab Realtime APIs";
  readonly supportedCountryCodes = new Set(["SE"]);
  private readonly cache = new Map<string, { loadedAt: number; value: Promise<ResolvedTimetableTrip | null> }>();

  constructor(
    private readonly apiKey: string,
    private readonly baseURL = defaultBaseURL,
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
  ) {}

  async platformUpdates(snapshot: TripSnapshot): Promise<PlatformObservation[]> {
    const resolved = await this.resolve(snapshot);
    if (resolved === null) return [];
    const observations: PlatformObservation[] = [];
    for (const stop of snapshot.stops) {
      if (!needsRealtimeUpdate(stop, snapshot)) continue;
      const id = areaId(stop);
      if (id === null) continue;
      const calls = resolved.calls.filter((call) => call.stop?.area_id === id);
      const tripCall = calls.length === 1 ? calls[0]! : null;
      const isAnchor = stop.sequence === resolved.anchor.stop.sequence;
      if (tripCall === null && !isAnchor) continue;
      const call = tripCall ?? resolved.boardCall;
      const plannedPlatform = designation(call.scheduled_platform);
      // The API fills realtime fields with scheduled values when is_realtime is
      // false. Those defaults must never outrank a published Regional update.
      const realtime = call.is_realtime === true;
      const expectedPlatform = realtime ? designation(call.realtime_platform) : null;
      let expectedArrival = realtime ? expectedTime(stop.scheduledArrival, call.realtimeArrival, call.arrivalDelay) : undefined;
      let expectedDeparture = realtime ? expectedTime(stop.scheduledDeparture, call.realtimeDeparture, call.departureDelay) : undefined;
      if (isAnchor && resolved.boardCall.is_realtime === true) {
        const boardExpected = expectedTime(resolved.anchor.scheduled, resolved.boardCall.realtime, resolved.boardCall.delay);
        if (resolved.anchor.direction === "departures") {
          expectedDeparture = boardExpected ?? expectedDeparture;
        } else {
          expectedArrival = boardExpected ?? expectedArrival;
        }
      }
      const cancellationValues = [
        ...[call.arrivalCanceled, call.departureCanceled].filter((value) => realtime || value === true),
        ...(isAnchor && (resolved.boardCall.is_realtime === true || resolved.boardCall.canceled === true)
          ? [resolved.boardCall.canceled] : []),
      ].filter((value): value is boolean => typeof value === "boolean");
      const cancelled = cancellationValues.length === 0
        ? undefined
        : cancellationValues.some((value) => value);
      if (plannedPlatform === null && expectedPlatform === null
        && expectedArrival === undefined && expectedDeparture === undefined && cancelled === undefined) continue;
      observations.push({
        stopSequence: stop.sequence,
        stationId: stop.stationId,
        ...(plannedPlatform === null ? {} : { plannedPlatform }),
        ...(expectedPlatform === null ? {} : { expectedPlatform }),
        ...(expectedArrival === undefined ? {} : { expectedArrival }),
        ...(expectedDeparture === undefined ? {} : { expectedDeparture }),
        ...(cancelled === undefined ? {} : { cancelled }),
        observedAt: resolved.observedAt,
        source: this.sourceName,
      });
    }
    return observations;
  }

  async tripAlertIds(snapshot: TripSnapshot): Promise<string[]> {
    const resolved = await this.resolve(snapshot);
    return resolved === null ? [] : alertIds(resolved);
  }

  private resolve(snapshot: TripSnapshot): Promise<ResolvedTimetableTrip | null> {
    const anchors = selectAnchors(snapshot);
    if (anchors.length === 0) return Promise.resolve(null);
    const now = this.now().getTime();
    const cached = this.cache.get(snapshot.id);
    if (cached !== undefined && now - cached.loadedAt < 30_000) return cached.value;
    const value = this.loadFirstMatch(snapshot, anchors);
    this.cache.set(snapshot.id, { loadedAt: now, value });
    if (this.cache.size > 200) this.cache.clear();
    return value;
  }

  private async loadFirstMatch(snapshot: TripSnapshot, anchors: Anchor[]): Promise<ResolvedTimetableTrip | null> {
    for (const anchor of anchors) {
      const result = await this.load(snapshot, anchor);
      if (result !== null) return result;
    }
    return null;
  }

  private async load(snapshot: TripSnapshot, anchor: Anchor): Promise<ResolvedTimetableTrip | null> {
    const boardURL = new URL(`${this.baseURL.replace(/\/$/u, "")}/${anchor.direction}/${anchor.areaId}/${minute(anchor.localScheduled)}`);
    boardURL.searchParams.set("key", this.apiKey);
    const boardResponse = await this.fetcher(boardURL, {
      headers: { accept: "application/json", "user-agent": "TrainTracker/0.4 (+https://github.com/jaguirre2192)" },
      signal: AbortSignal.timeout(15_000),
    });
    if (!boardResponse.ok) throw new Error(`Trafiklab timetable returned ${boardResponse.status}`);
    const board = await boardResponse.json() as TrafiklabBoardResponse;
    const entries = anchor.direction === "departures" ? board.departures ?? [] : board.arrivals ?? [];
    const candidates = entries.flatMap((call) => {
      if (call.route?.transport_mode !== "TRAIN" || minute(call.scheduled) !== minute(anchor.localScheduled)) return [];
      const tripId = call.trip?.trip_id?.trim();
      const startDate = call.trip?.start_date?.trim();
      if (tripId === undefined || tripId.length === 0 || startDate === undefined || startDate.length === 0) return [];
      const score = 60 + productScore(snapshot, call)
        + (startDate === snapshot.serviceDate ? 20 : 0) + directionScore(snapshot, call);
      return score >= 110 ? [{ call, score, tripId, startDate }] : [];
    }).sort((left, right) => right.score - left.score);
    if (candidates.length === 0 || (candidates[1]?.score ?? -1) === candidates[0]!.score) return null;
    const match = candidates[0]!;
    const tripURL = new URL(`${this.baseURL.replace(/\/$/u, "")}/trips/${encodeURIComponent(match.tripId)}/${encodeURIComponent(match.startDate)}`);
    tripURL.searchParams.set("key", this.apiKey);
    const tripResponse = await this.fetcher(tripURL, {
      headers: { accept: "application/json", "user-agent": "TrainTracker/0.4 (+https://github.com/jaguirre2192)" },
      signal: AbortSignal.timeout(15_000),
    });
    if (!tripResponse.ok) throw new Error(`Trafiklab trip details returned ${tripResponse.status}`);
    const trip = await tripResponse.json() as TrafiklabTripResponse;
    return {
      anchor,
      boardCall: match.call,
      calls: trip.calls ?? [],
      observedAt: this.now().toISOString(),
      tripId: match.tripId,
    };
  }
}
