import { realtimeCandidateStops } from "./realtime-stop-candidates.js";
import { createHash } from "node:crypto";
import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import { cachedLoad, ExpiringCache } from "./expiring-cache.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";
import { oebbInfoToGoStations } from "./oebb-infotogo-stations.generated.js";

const defaultWebSocketURL = "wss://meine.oebb.at/abfahrtankunft/webdisplay/web_client/ws/";

interface OebbLocalizedText {
  default?: string | null;
  de?: string | null;
  en?: string | null;
}

interface OebbDeparture {
  id: string;
  train: string;
  line?: string | null;
  product?: string | null;
  scheduled: string;
  expected?: string | null;
  track?: string | null;
  destination?: OebbLocalizedText | null;
  origin?: OebbLocalizedText | null;
  flags?: string[] | null;
}

interface OebbSpecialNotice {
  type?: string | null;
  flags?: string[] | null;
  text?: OebbLocalizedText | null;
}

export interface OebbInfoToGoBoard {
  departures?: OebbDeparture[] | null;
  arrivals?: OebbDeparture[] | null;
  specialNotices?: OebbSpecialNotice[] | null;
}

interface OebbRPCMessage {
  method?: string;
  params?: { data?: OebbInfoToGoBoard };
}

interface EnrichmentResult {
  observations: PlatformObservation[];
  alertIds: string[];
}

export type OebbBoardKind = "departure" | "arrival";
export type OebbInfoToGoLoader = (stationId: string, kind?: OebbBoardKind) => Promise<OebbInfoToGoBoard>;

function normalized(value: string | null | undefined): string {
  return value?.normalize("NFKD")
    .replace(/\p{Diacritic}/gu, "")
    .replace(/&(?:#8203|nbsp);/giu, " ")
    .replace(/\b(?:hauptbahnhof|hbf|bahnhof|bf|haltestelle)\b/giu, " ")
    .replace(/[^\p{Letter}\p{Number}]+/gu, " ")
    .trim()
    .toLowerCase() ?? "";
}

function compact(value: string | null | undefined): string {
  return normalized(value).replaceAll(" ", "");
}

function text(value: OebbLocalizedText | null | undefined): string {
  return value?.default?.trim() || value?.en?.trim() || value?.de?.trim() || "";
}

function platform(value: string | null | undefined): string | null {
  const result = value?.trim();
  return result === undefined || result.length === 0 || /^[-–—]+$/u.test(result) ? null : result;
}

function iso(value: string | null | undefined): string | null {
  if (value === null || value === undefined) return null;
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? null : new Date(parsed).toISOString();
}

function digest(value: string): string {
  return createHash("sha256").update(value).digest("hex").slice(0, 24);
}

function stationDistance(stop: StopSnapshot, station: readonly [string, string, number, number]): number {
  if (stop.latitude === null || stop.longitude === null) return Number.POSITIVE_INFINITY;
  const latitudeScale = 111.32;
  const longitudeScale = latitudeScale * Math.cos(stop.latitude * Math.PI / 180);
  return Math.hypot(
    (station[2] - stop.latitude) * latitudeScale,
    (station[3] - stop.longitude) * longitudeScale,
  );
}

function matchingStationId(stop: StopSnapshot): string | null {
  const name = normalized(stop.stationName);
  const candidates = oebbInfoToGoStations.map((station) => ({
    station,
    distance: stationDistance(stop, station),
    exactName: normalized(station[1]) === name,
  })).filter((candidate) => candidate.distance <= 3 && (candidate.exactName || candidate.distance <= 0.35))
    .sort((left, right) => Number(right.exactName) - Number(left.exactName) || left.distance - right.distance);
  const first = candidates[0];
  if (first === undefined) return null;
  const second = candidates[1];
  if (second !== undefined && first.exactName === second.exactName
    && Math.abs(first.distance - second.distance) < 0.05) return null;
  return first.station[0];
}

function trainNumbers(snapshot: TripSnapshot): Set<string> {
  const values = [snapshot.product, snapshot.nativeId].flatMap((value) => value.match(/\d{2,6}/gu) ?? []);
  return new Set(values.map((value) => value.replace(/^0+/u, "") || "0"));
}

function productScore(snapshot: TripSnapshot, departure: OebbDeparture): number {
  const snapshotProduct = compact(snapshot.product);
  const types = [departure.product, departure.line].map(compact).filter((value) => value.length > 0);
  if (types.some((value) => snapshotProduct.startsWith(value) || snapshotProduct.includes(value))) return 10;
  return 0;
}

function matchingDeparture(
  stop: StopSnapshot,
  snapshot: TripSnapshot,
  departures: OebbDeparture[],
): OebbDeparture | null {
  const eventTime = stop.scheduledDeparture ?? stop.scheduledArrival;
  if (eventTime === null) return null;
  const scheduled = Date.parse(eventTime);
  if (Number.isNaN(scheduled)) return null;
  const numbers = trainNumbers(snapshot);
  if (numbers.size === 0) return null;
  const headsign = normalized(snapshot.headsign);
  const candidates = departures.flatMap((departure) => {
    const planned = Date.parse(departure.scheduled);
    const number = departure.train.replace(/^0+/u, "") || "0";
    if (!numbers.has(number) || Number.isNaN(planned)) return [];
    const difference = Math.abs(planned - scheduled);
    if (difference > 5 * 60_000) return [];
    // Arrival rows identify the origin, which is not evidence for a destination.
    const destination = stop.scheduledDeparture === null ? "" : normalized(text(departure.destination));
    const destinationScore = destination.length > 0
      && (destination === headsign || destination.includes(headsign) || headsign.includes(destination)) ? 5 : 0;
    return [{ departure, difference, score: 20 + productScore(snapshot, departure) + destinationScore }];
  }).sort((left, right) => right.score - left.score || left.difference - right.difference);
  const first = candidates[0];
  if (first === undefined) return null;
  const second = candidates[1];
  if (second !== undefined && second.score === first.score && second.difference === first.difference) return null;
  return first.departure;
}

const disruptionFlags = new Set(["ANNOUNCEMENT", "DEVIATION", "ENDING", "NOT_IN_SERVICE", "PARTIAL_CANCELLATION"]);

function routeTerms(snapshot: TripSnapshot, currentStop: StopSnapshot): string[] {
  const current = normalized(currentStop.stationName);
  return [...new Set([
    normalized(snapshot.headsign),
    ...snapshot.stops.map((stop) => normalized(stop.stationName)),
    ...trainNumbers(snapshot),
  ].filter((value) => value.length >= 4 && value !== current))];
}

function alertIds(
  snapshot: TripSnapshot,
  stop: StopSnapshot,
  departure: OebbDeparture,
  notices: OebbSpecialNotice[],
): string[] {
  const movementAlerts = (departure.flags ?? []).filter((flag) => disruptionFlags.has(flag)).map((flag) =>
    `oebb:movement:${digest(`${departure.id}|${flag}`)}`
  );
  const terms = routeTerms(snapshot, stop);
  const routeNotices = notices.flatMap((notice) => {
    const value = text(notice.text);
    const haystack = normalized(value);
    if (value.length === 0 || !terms.some((term) => haystack.includes(term))) return [];
    return [`oebb:notice:${digest(`${notice.type ?? ""}|${(notice.flags ?? []).join(",")}|${value}`)}`];
  });
  return [...new Set([...movementAlerts, ...routeNotices])];
}

export function loadOebbInfoToGoBoard(
  stationId: string,
  webSocketURL = defaultWebSocketURL,
  timeoutMilliseconds = 8_000,
  kind: OebbBoardKind = "departure",
): Promise<OebbInfoToGoBoard> {
  const url = new URL(webSocketURL);
  url.search = new URLSearchParams({
    stationId,
    contentType: kind,
    staticLayout: "false",
    page: "1",
    offset: "0",
    ignoreIncident: "false",
    expandAll: "false",
  }).toString();
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url.toString());
    let settled = false;
    const finish = (value: OebbInfoToGoBoard | Error): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      try { socket.close(); } catch { /* already closed */ }
      if (value instanceof Error) reject(value);
      else resolve(value);
    };
    const timeout = setTimeout(() => finish(new Error("ÖBB InfoToGo timed out")), timeoutMilliseconds);
    socket.addEventListener("message", (event) => {
      try {
        const message = JSON.parse(String(event.data)) as OebbRPCMessage;
        if (message.method === "update" && message.params?.data !== undefined) finish(message.params.data);
      } catch {
        // Ignore non-JSON keepalive frames and wait for the first update payload.
      }
    });
    socket.addEventListener("error", () => finish(new Error("ÖBB InfoToGo WebSocket failed")));
    socket.addEventListener("close", () => finish(new Error("ÖBB InfoToGo closed before an update")));
  });
}

export class OebbInfoToGoOverlay implements PlatformRealtimeOverlay {
  readonly sourceName = "ÖBB InfoToGo";
  readonly supportedCountryCodes = new Set(["AT"]);
  private readonly boardCache = new ExpiringCache<Promise<OebbInfoToGoBoard>>(200);
  private readonly enrichmentCache = new ExpiringCache<Promise<EnrichmentResult>>(500);

  constructor(
    private readonly loader: OebbInfoToGoLoader = (stationId, kind) => loadOebbInfoToGoBoard(stationId, undefined, undefined, kind),
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
    const candidates = realtimeCandidateStops(snapshot, (stop) => stop.countryCode === "AT" && (stop.scheduledDeparture !== null || stop.scheduledArrival !== null), 1);
    const values = await Promise.all(candidates.map((stop) => this.loadStop(snapshot, stop)));
    return { observations: values.flatMap((value) => value.observations),
      alertIds: [...new Set(values.flatMap((value) => value.alertIds))] };
  }

  private async loadStop(snapshot: TripSnapshot, stop: StopSnapshot): Promise<EnrichmentResult> {
    const stationId = matchingStationId(stop);
    if (stationId === null) return { observations: [], alertIds: [] };
    const kind = stop.scheduledDeparture === null ? "arrival" : "departure";
    const board = await this.board(stationId, kind);
    const departure = matchingDeparture(stop, snapshot, (kind === "arrival" ? board.arrivals : board.departures) ?? []);
    if (departure === null) return { observations: [], alertIds: [] };
    const expectedDeparture = iso(departure.expected) ?? iso(departure.scheduled);
    const expectedPlatform = platform(departure.track);
    const cancelled = (departure.flags ?? []).includes("CANCELED");
    const observedAt = this.now().toISOString();
    const hasObservation = expectedDeparture !== null || expectedPlatform !== null || cancelled;
    return {
      observations: hasObservation ? [{
        stopSequence: stop.sequence,
        stationId: stop.stationId,
        ...(expectedPlatform === null ? {} : { expectedPlatform }),
        ...(expectedDeparture === null ? {} : kind === "arrival"
          ? { expectedArrival: expectedDeparture } : { expectedDeparture }),
        cancelled,
        observedAt,
        source: this.sourceName,
      }] : [],
      alertIds: alertIds(snapshot, stop, departure, board.specialNotices ?? []),
    };
  }

  private board(stationId: string, kind: OebbBoardKind): Promise<OebbInfoToGoBoard> {
    const now = this.now().getTime();
    return cachedLoad(this.boardCache, `${stationId}:${kind}`, now, 25_000, () => this.loader(stationId, kind));
  }
}
