import { realtimeCandidateStops } from "./realtime-stop-candidates.js";
import type { StopSnapshot, TripSnapshot, VehiclePositionSnapshot } from "../domain/snapshot.js";
import { cachedLoad, ExpiringCache } from "./expiring-cache.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";
import type { TripPositionOverlay } from "./trip-position-overlay.js";
import { zonedParts, zonedWallClockToUTC } from "./zoned-time.js";

const defaultBaseURL = "https://elron.ee";

interface ElronStop {
  peatus: string;
  latitude: string;
  longitude: string;
  teade?: string | null;
}

interface ElronBoardMovement {
  plaaniline_aeg: string;
  tegelik_aeg?: string | null;
  kuupaev: string;
  reis: string;
  liin: string;
  sihtjaam: string;
  erinevus_plaanist?: string | null;
  lisateade?: string | null;
  pohjus_teade?: string | null;
  peatuskoht?: string | null;
  peatuskoht_muutunud?: string | boolean | null;
  reisi_lopp_peatus?: string | boolean | null;
  reisi_staatus?: string | null;
}

interface ElronLiveTrain {
  reis: string;
  liin: string;
  reisi_algus_aeg?: string | null;
  reisi_lopp_aeg?: string | null;
  kiirus?: string | null;
  latitude: string;
  longitude: string;
  rongi_suund?: string | null;
  erinevus_plaanist?: string | null;
  lisateade?: string | null;
  pohjus_teade?: string | null;
  avalda_kodulehel?: string | null;
  asukoha_uuendus: string;
  reisi_staatus?: string | null;
  viimane_peatus?: string | null;
}

interface ElronResponse<Value> {
  data: Value[];
}

interface EnrichmentResult {
  observations: PlatformObservation[];
  alertIds: string[];
  positions: VehiclePositionSnapshot[];
}

function normalized(value: string): string {
  return value.normalize("NFKD")
    .replace(/\p{Diacritic}/gu, "")
    .replace(/\b(?:raudteejaam|rongijaam|train\s+station|station)\b/giu, " ")
    .replace(/[^\p{Letter}\p{Number}]+/gu, " ")
    .trim()
    .toLowerCase();
}

function finite(value: string | null | undefined): number | null {
  if (value === null || value === undefined || value.trim().length === 0) return null;
  const result = Number(value);
  return Number.isFinite(result) ? result : null;
}

function meaningful(value: string | null | undefined): string | null {
  const result = value?.trim();
  return result === undefined || result.length === 0 || /^[.\-–—]+$/u.test(result) ? null : result;
}

function trueFlag(value: string | boolean | null | undefined): boolean {
  return value === true || value === "t" || value === "true" || value === "1";
}

function tallinnLocal(date: string, time: string): string | null {
  if (!/^\d{4}-\d{2}-\d{2}$/u.test(date) || !/^\d{2}:\d{2}(?::\d{2})?$/u.test(time)) return null;
  const [year, month, day] = date.split("-").map(Number);
  const [hour, minute, second = 0] = time.split(":").map(Number);
  if (year === undefined || month === undefined || day === undefined || hour === undefined || minute === undefined) return null;
  return new Date(zonedWallClockToUTC("Europe/Tallinn", year, month, day, hour, minute, second)).toISOString();
}

function localDateTime(iso: string): { date: string; time: string } | null {
  const parsed = Date.parse(iso);
  if (Number.isNaN(parsed)) return null;
  const value = zonedParts(parsed, "Europe/Tallinn");
  const pad = (number: number) => String(number).padStart(2, "0");
  return {
    date: `${value.year}-${pad(value.month)}-${pad(value.day)}`,
    time: `${pad(value.hour)}:${pad(value.minute)}`,
  };
}

function distance(stop: StopSnapshot, candidate: ElronStop): number {
  if (stop.latitude === null || stop.longitude === null) return Number.POSITIVE_INFINITY;
  const latitude = finite(candidate.latitude);
  const longitude = finite(candidate.longitude);
  if (latitude === null || longitude === null) return Number.POSITIVE_INFINITY;
  return Math.hypot(latitude - stop.latitude, longitude - stop.longitude);
}

function matchingStop(stop: StopSnapshot, candidates: ElronStop[]): ElronStop | null {
  const requested = normalized(stop.stationName);
  const matches = candidates.map((candidate) => {
    const actual = normalized(candidate.peatus);
    const separation = distance(stop, candidate);
    const nameScore = actual === requested ? 50
      : requested.length > 2 && actual.length > 2 && (actual.includes(requested) || requested.includes(actual)) ? 25 : 0;
    const distanceScore = separation <= 0.002 ? 20 : separation <= 0.01 ? 10 : separation <= 0.025 ? 5 : 0;
    return { candidate, separation, score: nameScore + distanceScore };
  }).filter((candidate) => candidate.score >= 25
    && (candidate.separation <= 0.025 || (!Number.isFinite(candidate.separation) && candidate.score >= 50)))
    .sort((left, right) => right.score - left.score || left.separation - right.separation);
  if (matches.length === 0) return null;
  if (matches.length > 1 && matches[0]!.score === matches[1]!.score
    && Math.abs(matches[0]!.separation - matches[1]!.separation) < 0.00001) return null;
  return matches[0]!.candidate;
}

function timeDifferenceMinutes(left: string, right: string): number {
  const [leftHour, leftMinute] = left.split(":").map(Number);
  const [rightHour, rightMinute] = right.split(":").map(Number);
  if (leftHour === undefined || leftMinute === undefined || rightHour === undefined || rightMinute === undefined) {
    return Number.POSITIVE_INFINITY;
  }
  return Math.abs(leftHour * 60 + leftMinute - (rightHour * 60 + rightMinute));
}

function directionScore(snapshot: TripSnapshot, movement: ElronBoardMovement): number {
  const headsign = normalized(snapshot.headsign);
  const destination = normalized(movement.sihtjaam);
  if (headsign === destination) return 30;
  if (headsign.length > 2 && destination.length > 2
    && (headsign.includes(destination) || destination.includes(headsign))) return 20;
  const line = normalized(movement.liin);
  return headsign.length > 2 && line.includes(headsign) ? 10 : 0;
}

function matchingMovement(
  snapshot: TripSnapshot,
  stop: StopSnapshot,
  movements: ElronBoardMovement[],
): ElronBoardMovement | null {
  const scheduled = stop.scheduledDeparture ?? stop.scheduledArrival;
  if (scheduled === null) return null;
  const local = localDateTime(scheduled);
  if (local === null) return null;
  const candidates = movements.filter((movement) => movement.kuupaev === local.date)
    .map((movement) => ({
      movement,
      difference: timeDifferenceMinutes(local.time, movement.plaaniline_aeg),
      direction: directionScore(snapshot, movement),
    }))
    .filter((candidate) => candidate.difference <= 3 && candidate.direction >= 10)
    .sort((left, right) => right.direction - left.direction || left.difference - right.difference);
  if (candidates.length === 0) return null;
  if (candidates.length > 1 && candidates[0]!.direction === candidates[1]!.direction
    && candidates[0]!.difference === candidates[1]!.difference) return null;
  return candidates[0]!.movement;
}

function cancellationStatus(value: string | null | undefined): boolean {
  const status = normalized(value ?? "");
  return /(?:tuhist|ara\s+ja|ei\s+soida|katkest|cancel)/u.test(status);
}

function fnv1a(value: string): string {
  let hash = 0x811c9dc5;
  for (const character of value) {
    hash ^= character.codePointAt(0) ?? 0;
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}

function alertIds(
  movement: ElronBoardMovement,
  liveTrain: ElronLiveTrain | null,
  stopName: string,
): string[] {
  const values = [
    meaningful(movement.lisateade),
    meaningful(movement.pohjus_teade),
    meaningful(liveTrain?.lisateade),
    meaningful(liveTrain?.pohjus_teade),
    meaningful(liveTrain?.avalda_kodulehel),
  ].flatMap((value) => value === null ? [] : [value]);
  const ids = values.map((value) => `elron:${fnv1a(`${movement.reis}|${value}`)}`);
  if (trueFlag(movement.peatuskoht_muutunud)) {
    ids.push(`elron:platform-change:${movement.kuupaev}:${movement.reis}:${fnv1a(stopName)}:${movement.peatuskoht ?? "-"}`);
  }
  return [...new Set(ids)];
}

function observation(
  snapshotStop: StopSnapshot,
  movement: ElronBoardMovement,
  liveTrain: ElronLiveTrain | null,
  observedAt: string,
): PlatformObservation | null {
  const currentPlatform = meaningful(movement.peatuskoht);
  const changedPlatform = trueFlag(movement.peatuskoht_muutunud);
  const delay = finite(movement.erinevus_plaanist) ?? finite(liveTrain?.erinevus_plaanist);
  const scheduled = snapshotStop.scheduledDeparture ?? snapshotStop.scheduledArrival;
  const expected = delay === null || scheduled === null ? null : new Date(Date.parse(scheduled) + delay * 60_000).toISOString();
  const cancelled = cancellationStatus(movement.reisi_staatus) || cancellationStatus(liveTrain?.reisi_staatus);
  if (currentPlatform === null && expected === null && !cancelled) return null;
  return {
    stopSequence: snapshotStop.sequence,
    stationId: snapshotStop.stationId,
    ...(changedPlatform ? {} : { plannedPlatform: currentPlatform }),
    expectedPlatform: currentPlatform,
    ...(snapshotStop.scheduledDeparture === null && expected !== null ? { expectedArrival: expected } : {}),
    ...(snapshotStop.scheduledDeparture !== null && expected !== null ? { expectedDeparture: expected } : {}),
    cancelled,
    observedAt,
    source: "Elron live map",
  };
}

function position(liveTrain: ElronLiveTrain | null, now: Date): VehiclePositionSnapshot[] {
  if (liveTrain === null) return [];
  const latitude = finite(liveTrain.latitude);
  const longitude = finite(liveTrain.longitude);
  const asOf = tallinnLocal(...liveTrain.asukoha_uuendus.split(" ", 2) as [string, string]);
  if (latitude === null || longitude === null || asOf === null || latitude === 0 || longitude === 0) return [];
  const age = now.getTime() - Date.parse(asOf);
  if (age < -2 * 60_000 || age > 2 * 60_000) return [];
  const heading = finite(liveTrain.rongi_suund);
  return [{
    latitude,
    longitude,
    heading,
    source: "real",
    confidence: age <= 30_000 ? 1 : 0.9,
    asOf,
    provider: "Elron live map",
  }];
}

export class ElronRealtimeOverlay implements PlatformRealtimeOverlay, TripPositionOverlay {
  readonly sourceName = "Elron live map";
  readonly supportedCountryCodes = new Set(["EE"]);
  private stopsCache: { loadedAt: number; value: Promise<ElronStop[]> } | null = null;
  private trainsCache: { loadedAt: number; value: Promise<ElronLiveTrain[]> } | null = null;
  private readonly boardCache = new ExpiringCache<Promise<ElronBoardMovement[]>>(200);
  private readonly enrichmentCache = new ExpiringCache<Promise<EnrichmentResult>>(500);

  constructor(
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

  async positionUpdates(snapshot: TripSnapshot): Promise<VehiclePositionSnapshot[]> {
    return (await this.enrich(snapshot)).positions;
  }

  private enrich(snapshot: TripSnapshot): Promise<EnrichmentResult> {
    const loadedAt = this.now().getTime();
    return cachedLoad(this.enrichmentCache, snapshot.id, loadedAt, 15_000, () => this.loadEnrichment(snapshot));
  }

  private async loadEnrichment(snapshot: TripSnapshot): Promise<EnrichmentResult> {
    const candidates = realtimeCandidateStops(snapshot, (stop) => stop.countryCode.toUpperCase() === "EE"
      && (stop.scheduledDeparture !== null || stop.scheduledArrival !== null), 1);
    const values = await Promise.all(candidates.map((stop) => this.loadStop(snapshot, stop)));
    const positions = values.flatMap((value) => value.positions);
    return { observations: values.flatMap((value) => value.observations),
      alertIds: [...new Set(values.flatMap((value) => value.alertIds))],
      positions: [...new Map(positions.map((position) => [`${position.provider}:${position.asOf}`, position])).values()] };
  }

  private async loadStop(snapshot: TripSnapshot, anchor: StopSnapshot): Promise<EnrichmentResult> {
    const officialStop = matchingStop(anchor, await this.stops());
    if (officialStop === null) return { observations: [], alertIds: [], positions: [] };
    const movement = matchingMovement(snapshot, anchor, await this.board(officialStop.peatus));
    if (movement === null) return { observations: [], alertIds: [], positions: [] };
    const liveMatches = (await this.liveTrains()).filter((candidate) => candidate.reis === movement.reis);
    const liveTrain = liveMatches.length === 1 ? liveMatches[0]! : null;
    const observedAt = this.now().toISOString();
    const value = observation(anchor, movement, liveTrain, observedAt);
    return {
      observations: value === null ? [] : [value],
      alertIds: alertIds(movement, liveTrain, officialStop.peatus),
      positions: position(liveTrain, this.now()),
    };
  }

  private stops(): Promise<ElronStop[]> {
    const loadedAt = this.now().getTime();
    if (this.stopsCache !== null && loadedAt - this.stopsCache.loadedAt < 24 * 60 * 60_000) return this.stopsCache.value;
    const value = this.json<ElronStop>("stops_data.json");
    this.stopsCache = { loadedAt, value };
    return value;
  }

  private liveTrains(): Promise<ElronLiveTrain[]> {
    const loadedAt = this.now().getTime();
    if (this.trainsCache !== null && loadedAt - this.trainsCache.loadedAt < 15_000) return this.trainsCache.value;
    const value = this.json<ElronLiveTrain>("map_data.json");
    this.trainsCache = { loadedAt, value };
    return value;
  }

  private board(stopName: string): Promise<ElronBoardMovement[]> {
    const loadedAt = this.now().getTime();
    return cachedLoad(this.boardCache, stopName, loadedAt, 30_000, () =>
      this.json<ElronBoardMovement>(`live-map/stop/${encodeURIComponent(stopName)}`));
  }

  private async json<Value>(path: string): Promise<Value[]> {
    const response = await this.fetcher(new URL(path, `${this.baseURL}/`), {
      headers: {
        accept: "application/json",
        "user-agent": "TrainTracker/0.4 (+https://github.com/jaguirre2192)",
      },
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) throw new Error(`Elron live map returned ${response.status}`);
    const body = await response.json() as ElronResponse<Value>;
    return Array.isArray(body.data) ? body.data : [];
  }
}
