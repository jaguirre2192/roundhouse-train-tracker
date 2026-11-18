import { realtimeCandidateStops } from "./realtime-stop-candidates.js";
import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import { cachedLoad, ExpiringCache } from "./expiring-cache.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";
import type {
  HafasValue,
  MobiliteitDeparture,
  MobiliteitDepartureResponse,
  MobiliteitLocationResponse,
  MobiliteitMessage,
  MobiliteitPassStop,
  MobiliteitPlatform,
  MobiliteitProduct,
  MobiliteitStopLocation,
} from "./mobiliteit-lu-types.js";

const defaultBaseURL = "https://cdt.hafas.de/opendata/apiserver";
const luxembourgTime = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Europe/Luxembourg",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hourCycle: "h23",
});

interface EnrichmentResult {
  observations: PlatformObservation[];
  alertIds: string[];
}

function array<Value>(value: Value | Value[] | null | undefined): Value[] {
  if (value === null || value === undefined) return [];
  return Array.isArray(value) ? value : [value];
}

function text(value: HafasValue): string | null {
  if (typeof value !== "string" && typeof value !== "number") return null;
  const result = String(value).trim();
  return result.length === 0 ? null : result;
}

function number(value: HafasValue): number | null {
  if (typeof value !== "string" && typeof value !== "number") return null;
  const result = Number(value);
  return Number.isFinite(result) ? result : null;
}

function flag(value: HafasValue): boolean | undefined {
  if (value === true || value === "true" || value === "1" || value === 1) return true;
  if (value === false || value === "false" || value === "0" || value === 0) return false;
  return undefined;
}

function normalized(value: string): string {
  return value.normalize("NFKD")
    .replace(/\p{Diacritic}/gu, "")
    .replace(/\b(?:gare\s+centrale|gare|station|bahnhof|quai)\b/giu, " ")
    .replace(/[^\p{Letter}\p{Number}]+/gu, " ")
    .trim()
    .toLowerCase();
}

function compact(value: string): string {
  return normalized(value).replaceAll(" ", "");
}

function coordinate(value: HafasValue, latitude: boolean): number | null {
  const result = number(value);
  if (result === null) return null;
  const limit = latitude ? 90 : 180;
  return Math.abs(result) <= limit ? result : result / 1_000_000;
}

function distance(stop: StopSnapshot, location: MobiliteitStopLocation): number {
  if (stop.latitude === null || stop.longitude === null) return Number.POSITIVE_INFINITY;
  const latitude = coordinate(location.lat, true);
  const longitude = coordinate(location.lon, false);
  if (latitude === null || longitude === null) return Number.POSITIVE_INFINITY;
  return Math.hypot(latitude - stop.latitude, longitude - stop.longitude);
}

function stationScore(stop: StopSnapshot, location: MobiliteitStopLocation): number {
  const requested = normalized(stop.stationName);
  const actualName = text(location.name);
  if (actualName === null) return 0;
  const actual = normalized(actualName);
  let score = requested === actual ? 40 : 0;
  if (score === 0 && requested.length > 2 && actual.length > 2
    && (requested.includes(actual) || actual.includes(requested))) score += 20;
  const requestedTokens = new Set(requested.split(" ").filter(Boolean));
  const sharedTokens = actual.split(" ").filter((token) => requestedTokens.has(token)).length;
  score += Math.min(15, sharedTokens * 5);
  const separation = distance(stop, location);
  if (separation <= 0.002) score += 20;
  else if (separation <= 0.008) score += 12;
  else if (separation <= 0.02) score += 5;
  return score;
}

function matchingLocation(stop: StopSnapshot, locations: MobiliteitStopLocation[]): MobiliteitStopLocation | null {
  const candidates = locations.map((location) => ({
    location,
    score: stationScore(stop, location),
    distance: distance(stop, location),
  })).filter((candidate) => candidate.score >= 20
    && (candidate.distance <= 0.02 || (!Number.isFinite(candidate.distance) && candidate.score >= 40)))
    .sort((left, right) => right.score - left.score || left.distance - right.distance);
  if (candidates.length === 0) return null;
  if (candidates.length > 1 && candidates[0]!.score === candidates[1]!.score
    && Math.abs(candidates[0]!.distance - candidates[1]!.distance) < 0.00001) return null;
  return candidates[0]!.location;
}

function timeParts(date: Date): Record<string, string> {
  return Object.fromEntries(luxembourgTime.formatToParts(date)
    .filter((part) => part.type !== "literal")
    .map((part) => [part.type, part.value]));
}

function zoneOffsetAt(utcMilliseconds: number): number {
  const parts = timeParts(new Date(utcMilliseconds));
  const asUTC = Date.UTC(
    Number(parts.year),
    Number(parts.month) - 1,
    Number(parts.day),
    Number(parts.hour),
    Number(parts.minute),
    Number(parts.second),
  );
  return asUTC - utcMilliseconds;
}

function hafasTime(dateValue: HafasValue, timeValue: HafasValue, timezoneValue: HafasValue): string | null {
  const date = text(dateValue);
  const time = text(timeValue);
  if (date === null || time === null || !/^\d{4}-\d{2}-\d{2}$/u.test(date)
    || !/^\d{2}:\d{2}(?::\d{2})?$/u.test(time)) return null;
  const [year, month, day] = date.split("-").map(Number);
  const [hour, minute, second = 0] = time.split(":").map(Number);
  if (year === undefined || month === undefined || day === undefined || hour === undefined || minute === undefined) return null;
  const localAsUTC = Date.UTC(year, month - 1, day, hour, minute, second);
  const timezoneMinutes = number(timezoneValue);
  let result = timezoneMinutes === null ? localAsUTC - zoneOffsetAt(localAsUTC) : localAsUTC - timezoneMinutes * 60_000;
  if (timezoneMinutes === null) result = localAsUTC - zoneOffsetAt(result);
  return new Date(result).toISOString();
}

function requestDateTime(iso: string): { date: string; time: string } | null {
  const milliseconds = Date.parse(iso);
  if (Number.isNaN(milliseconds)) return null;
  const parts = timeParts(new Date(milliseconds - 10 * 60_000));
  if (parts.year === undefined || parts.month === undefined || parts.day === undefined
    || parts.hour === undefined || parts.minute === undefined) return null;
  return { date: `${parts.year}-${parts.month}-${parts.day}`, time: `${parts.hour}:${parts.minute}:00` };
}

function products(departure: MobiliteitDeparture): MobiliteitProduct[] {
  return [...array(departure.ProductAtStop), ...array(departure.Product)];
}

function stopLocations(response: MobiliteitLocationResponse): MobiliteitStopLocation[] {
  return [
    ...array(response.StopLocation),
    ...array(response.stopLocationOrCoordLocation).flatMap((entry) =>
      entry.StopLocation === undefined ? [] : [entry.StopLocation]),
  ];
}

function identityValues(departure: MobiliteitDeparture): string[] {
  return [
    departure.name,
    ...products(departure).flatMap((product) => [
      product.name,
      product.displayNumber,
      product.num,
      product.line,
      product.catOut,
      product.catOutS,
      product.catOutL,
      product.catCode,
    ]),
  ].flatMap((value) => {
    const result = text(value);
    return result === null ? [] : [result];
  });
}

function productScore(snapshot: TripSnapshot, departure: MobiliteitDeparture): number {
  const requested = compact(snapshot.product);
  const identities = identityValues(departure);
  if (identities.some((identity) => compact(identity) === requested)) return 50;
  if (requested.length > 2 && identities.some((identity) => {
    const candidate = compact(identity);
    return candidate.length > 2 && (candidate.includes(requested) || requested.includes(candidate));
  })) return 35;
  const numbers: string[] = [...(snapshot.product.match(/\d+/gu) ?? [])];
  if (numbers.length > 0 && identities.some((identity) =>
    [...(identity.match(/\d+/gu) ?? [])].some((candidate) => numbers.includes(candidate)))) return 30;
  return 0;
}

function matchingDeparture(snapshot: TripSnapshot, anchor: StopSnapshot, departures: MobiliteitDeparture[]): MobiliteitDeparture | null {
  const scheduled = anchor.scheduledDeparture;
  if (scheduled === null) return null;
  const scheduledMilliseconds = Date.parse(scheduled);
  const headsign = normalized(snapshot.headsign);
  const candidates = departures.map((departure) => {
    const planned = hafasTime(departure.date, departure.time, departure.tz);
    const difference = planned === null ? Number.POSITIVE_INFINITY : Math.abs(Date.parse(planned) - scheduledMilliseconds);
    const direction = normalized(text(departure.direction) ?? "");
    const directionScore = direction === headsign ? 10
      : direction.length > 2 && headsign.length > 2 && (direction.includes(headsign) || headsign.includes(direction)) ? 5 : 0;
    return { departure, difference, score: productScore(snapshot, departure) + directionScore };
  }).filter((candidate) => candidate.difference <= 10 * 60_000 && candidate.score >= 30)
    .sort((left, right) => right.score - left.score || left.difference - right.difference);
  if (candidates.length === 0) return null;
  if (candidates.length > 1 && candidates[0]!.score === candidates[1]!.score
    && candidates[0]!.difference === candidates[1]!.difference) return null;
  return candidates[0]!.departure;
}

function visiblePlatform(structured: MobiliteitPlatform | undefined, track: HafasValue, hidden: HafasValue): string | null {
  if (flag(hidden) === true || flag(structured?.hidden) === true) return null;
  return text(structured?.text) ?? text(track);
}

function stopObservation(
  snapshotStop: StopSnapshot,
  officialStop: MobiliteitPassStop,
  wholeTripCancelled: boolean,
  observedAt: string,
): PlatformObservation | null {
  const plannedDeparture = visiblePlatform(officialStop.depPlatform, officialStop.depTrack, officialStop.depTrackHidden);
  const realtimeDeparture = visiblePlatform(officialStop.rtDepPlatform, officialStop.rtDepTrack, officialStop.rtDepTrackHidden);
  const plannedArrival = visiblePlatform(officialStop.arrPlatform, officialStop.arrTrack, officialStop.arrTrackHidden);
  const realtimeArrival = visiblePlatform(officialStop.rtArrPlatform, officialStop.rtArrTrack, officialStop.rtArrTrackHidden);
  const usesArrival = snapshotStop.scheduledArrival !== null;
  const usesDeparture = snapshotStop.scheduledDeparture !== null;
  const plannedPlatform = usesDeparture ? plannedDeparture ?? plannedArrival : plannedArrival ?? plannedDeparture;
  const expectedPlatform = usesDeparture
    ? realtimeDeparture ?? plannedDeparture ?? realtimeArrival ?? plannedArrival
    : realtimeArrival ?? plannedArrival ?? realtimeDeparture ?? plannedDeparture;
  const expectedArrival = !usesArrival || officialStop.rtArrTime === undefined ? null : hafasTime(
    officialStop.rtArrDate ?? officialStop.arrDate,
    officialStop.rtArrTime,
    officialStop.rtArrTz ?? officialStop.arrTz,
  );
  const expectedDeparture = !usesDeparture || officialStop.rtDepTime === undefined ? null : hafasTime(
    officialStop.rtDepDate ?? officialStop.depDate,
    officialStop.rtDepTime,
    officialStop.rtDepTz ?? officialStop.depTz,
  );
  const cancelled = wholeTripCancelled || flag(officialStop.cancelled) === true
    || (usesArrival && flag(officialStop.cancelledArrival) === true)
    || (usesDeparture && flag(officialStop.cancelledDeparture) === true);
  if (plannedPlatform === null && expectedPlatform === null && expectedArrival === null
    && expectedDeparture === null && !cancelled) return null;
  return {
    stopSequence: snapshotStop.sequence,
    stationId: snapshotStop.stationId,
    plannedPlatform,
    expectedPlatform,
    ...(expectedArrival === null ? {} : { expectedArrival }),
    ...(expectedDeparture === null ? {} : { expectedDeparture }),
    cancelled,
    observedAt,
    source: "mobiliteit.lu OpenAPI",
  };
}

function messageIds(messages: MobiliteitMessage[]): string[] {
  return [...new Set(messages.flatMap((message) => {
    if (flag(message.act) === false) return [];
    const id = text(message.externalId) ?? text(message.id);
    return id === null ? [] : [`mobiliteit-lu:${id}`];
  }))];
}

function foreignArrivalAnchors(snapshot: TripSnapshot): StopSnapshot[] {
  const terminal = snapshot.stops.find((stop) => stop.countryCode.toUpperCase() === "LU"
    && stop.scheduledArrival !== null && stop.latitude !== null && stop.longitude !== null);
  if (terminal === undefined) return [];
  const terminalIndex = snapshot.stops.indexOf(terminal);
  // The public API has departureBoard only. A nearby preceding foreign stop can
  // expose the same through service's full passlist, including its LU arrival.
  return snapshot.stops.slice(0, terminalIndex).filter((stop) =>
    ["DE", "FR", "BE"].includes(stop.countryCode.toUpperCase()) && stop.scheduledDeparture !== null
    && stop.latitude !== null && stop.longitude !== null
    && Math.hypot((stop.latitude - terminal.latitude!) * 111.32,
      (stop.longitude - terminal.longitude!) * 111.32 * Math.cos(terminal.latitude! * Math.PI / 180)) < 150
  ).reverse().slice(0, 2);
}

function sameScheduledArrival(stop: StopSnapshot, official: MobiliteitPassStop): boolean {
  const aimed = hafasTime(official.arrDate, official.arrTime, official.arrTz);
  return stop.scheduledArrival !== null && aimed !== null
    && Math.abs(Date.parse(aimed) - Date.parse(stop.scheduledArrival)) <= 90_000;
}

export class MobiliteitLuRealtimeOverlay implements PlatformRealtimeOverlay {
  readonly sourceName = "mobiliteit.lu OpenAPI";
  readonly supportedCountryCodes = new Set(["LU"]);
  private readonly stationCache = new ExpiringCache<Promise<MobiliteitStopLocation | null>>(500);
  private readonly boardCache = new ExpiringCache<Promise<MobiliteitDeparture[]>>(200);
  private readonly enrichmentCache = new ExpiringCache<Promise<EnrichmentResult>>(500);

  constructor(
    private readonly accessId: string,
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
    const now = this.now().getTime();
    return cachedLoad(this.enrichmentCache, snapshot.id, now, 15_000, () => this.loadEnrichment(snapshot));
  }

  private async loadEnrichment(snapshot: TripSnapshot): Promise<EnrichmentResult> {
    const localAnchors = realtimeCandidateStops(snapshot, (stop) => stop.countryCode.toUpperCase() === "LU"
      && stop.scheduledDeparture !== null && stop.latitude !== null && stop.longitude !== null, 1);
    const anchors = localAnchors.length > 0 ? localAnchors : foreignArrivalAnchors(snapshot);
    for (const anchor of anchors) {
      const result = await this.loadFromAnchor(snapshot, anchor);
      if (result !== null) return result;
    }
    return { observations: [], alertIds: [] };
  }

  private async loadFromAnchor(snapshot: TripSnapshot, anchor: StopSnapshot): Promise<EnrichmentResult | null> {
    if (anchor.scheduledDeparture === null) return null;
    const station = await this.station(anchor);
    const stationId = text(station?.id) ?? text(station?.extId);
    const requestTime = requestDateTime(anchor.scheduledDeparture);
    if (stationId === null || requestTime === null) return null;
    const departure = matchingDeparture(snapshot, anchor, await this.departures(stationId, requestTime));
    if (departure === null) return null;
    const officialStops = array(departure.Stops?.Stop);
    const foreignAnchor = anchor.countryCode.toUpperCase() !== "LU";
    if (foreignAnchor && !snapshot.stops.some((stop) => {
      if (stop.countryCode.toUpperCase() !== "LU") return false;
      const official = matchingLocation(stop, officialStops) as MobiliteitPassStop | null;
      return official !== null && sameScheduledArrival(stop, official);
    })) return null;
    const observedAt = this.now().toISOString();
    const wholeTripCancelled = flag(departure.cancelled) === true
      || text(departure.JourneyStatus)?.toUpperCase() === "C";
    const observations = snapshot.stops.filter((stop) => stop.countryCode.toUpperCase() === "LU").flatMap((stop) => {
      const officialStop = matchingLocation(stop, officialStops) as MobiliteitPassStop | null;
      if (officialStop === null || (foreignAnchor && !sameScheduledArrival(stop, officialStop))) return [];
      const observation = stopObservation(stop, officialStop, wholeTripCancelled, observedAt);
      return observation === null ? [] : [observation];
    });
    return {
      observations,
      alertIds: messageIds(array(departure.Messages?.Message)),
    };
  }

  private station(stop: StopSnapshot): Promise<MobiliteitStopLocation | null> {
    const key = `${stop.stationId}:${stop.latitude?.toFixed(4)}:${stop.longitude?.toFixed(4)}`;
    const now = this.now().getTime();
    return cachedLoad(this.stationCache, key, now, 24 * 60 * 60_000, () =>
      this.json<MobiliteitLocationResponse>("location.nearbystops", {
        originCoordLat: String(stop.latitude),
        originCoordLong: String(stop.longitude),
        r: "1500",
        maxNo: "30",
        type: "SE",
      }).then((response) => matchingLocation(stop, stopLocations(response))));
  }

  private departures(stationId: string, requestTime: { date: string; time: string }): Promise<MobiliteitDeparture[]> {
    const key = `${stationId}:${requestTime.date}:${requestTime.time}`;
    const now = this.now().getTime();
    return cachedLoad(this.boardCache, key, now, 120_000, () =>
      this.json<MobiliteitDepartureResponse>("departureBoard", {
        id: stationId,
        date: requestTime.date,
        time: requestTime.time,
        duration: "30",
        maxJourneys: "80",
        passlist: "1",
        passlistMaxStops: "256",
        rtMode: "SERVER_DEFAULT",
        type: "DEP_STATION",
      }).then((response) => array(response.Departure)));
  }

  private async json<Response extends { errorCode?: string; errorText?: string }>(
    path: string,
    query: Record<string, string>,
  ): Promise<Response> {
    const url = new URL(path, `${this.baseURL}/`);
    url.searchParams.set("accessId", this.accessId);
    url.searchParams.set("format", "json");
    url.searchParams.set("lang", "en");
    for (const [key, value] of Object.entries(query)) url.searchParams.set(key, value);
    const response = await this.fetcher(url, {
      headers: {
        accept: "application/json",
        "user-agent": "TrainTracker/0.4 (+https://github.com/jaguirre2192)",
      },
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) throw new Error(`mobiliteit.lu OpenAPI returned ${response.status}`);
    const body = await response.json() as Response;
    if (body.errorCode !== undefined) throw new Error(`mobiliteit.lu OpenAPI error ${body.errorCode}`);
    return body;
  }
}
