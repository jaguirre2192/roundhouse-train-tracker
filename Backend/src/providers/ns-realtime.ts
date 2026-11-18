import { realtimeCandidateStops } from "./realtime-stop-candidates.js";
import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import { cachedLoad, ExpiringCache } from "./expiring-cache.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";

const defaultBaseURL = "https://gateway.apiportal.ns.nl/reisinformatie-api/api/v2";

interface NSStation {
  UICCode: string;
  code: string;
  namen: { lang: string; middel: string; kort: string };
  lat: number;
  lng: number;
  land: string;
}

interface NSMessage {
  message: string;
  style?: string | null;
}

interface NSMovement {
  direction?: string | null;
  origin?: string | null;
  name?: string | null;
  plannedDateTime: string;
  actualDateTime?: string | null;
  plannedTrack?: string | null;
  actualTrack?: string | null;
  cancelled: boolean;
  messages?: NSMessage[] | null;
  product: {
    number?: string | null;
    categoryCode?: string | null;
    shortCategoryName?: string | null;
    longCategoryName?: string | null;
    operatorName?: string | null;
    type?: string | null;
  };
}

interface NSStationsResponse {
  payload: NSStation[];
}

interface NSMovementsResponse {
  payload: { departures?: NSMovement[]; arrivals?: NSMovement[] };
}

interface EnrichmentResult {
  observations: PlatformObservation[];
  alertIds: string[];
  trainNumbers: Map<number, string>;
}

function normalized(value: string | null | undefined): string {
  if (typeof value !== "string") return "";
  return value.normalize("NFKD")
    .replace(/\p{Diacritic}/gu, "")
    .replace(/[^\p{Letter}\p{Number}]+/gu, " ")
    .trim()
    .toLowerCase();
}

function platform(value: string | null | undefined): string | null {
  const result = value?.trim();
  return result === undefined || result.length === 0 ? null : result;
}

function iso(value: string | null | undefined): string | null {
  if (value === null || value === undefined) return null;
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? null : new Date(parsed).toISOString();
}

function distance(stop: StopSnapshot, station: NSStation): number {
  if (stop.latitude === null || stop.longitude === null) return Number.POSITIVE_INFINITY;
  return Math.hypot(station.lat - stop.latitude, station.lng - stop.longitude);
}

function matchingStation(stop: StopSnapshot, stations: NSStation[]): NSStation | null {
  const name = normalized(stop.stationName);
  const dutchStations = stations.filter((station) => station.land.toUpperCase() === "NL");
  const exact = dutchStations.find((station) =>
    name.length > 0 && [station.namen.lang, station.namen.middel, station.namen.kort]
      .some((candidate) => normalized(candidate) === name)
  );
  if (exact !== undefined) return exact;
  const nearest = dutchStations.map((station) => ({ station, distance: distance(stop, station) }))
    .filter((candidate) => candidate.distance < 0.025)
    .sort((left, right) => left.distance - right.distance)[0];
  return nearest?.station ?? null;
}

function identityStrings(movement: NSMovement): string[] {
  return [
    movement.name,
    movement.product.number,
    movement.product.categoryCode,
    movement.product.shortCategoryName,
    movement.product.longCategoryName,
  ].map(normalized).filter((candidate) => candidate.length > 0);
}

function productScore(snapshot: TripSnapshot, movement: NSMovement): number {
  const product = normalized(snapshot.product);
  if (product.length === 0) return 0;
  const identities = identityStrings(movement);
  const numbers: string[] = snapshot.product.match(/\d+/gu) ?? [];
  if (numbers.length > 0) {
    const movementNumber = movement.product.number?.trim();
    // An explicit train number cannot be replaced by another train of the same category.
    if (movementNumber !== undefined && movementNumber.length > 0) return numbers.includes(movementNumber) ? 20 : 0;
    return identities.some((candidate) => candidate === product) ? 20 : 0;
  }
  if (identities.some((candidate) => candidate === product)) return 20;
  if (product.includes("sprinter") && identities.some((candidate) => candidate.includes("sprinter"))) return 15;
  if (/\b(?:ic|intercity)\b/iu.test(snapshot.product)
    && identities.some((candidate) => /\b(?:ic|intercity)\b/iu.test(candidate))) return 15;
  return 0;
}

function matchingMovement(stop: StopSnapshot, snapshot: TripSnapshot, movements: NSMovement[], kind: "arrivals" | "departures"): NSMovement | null {
  const scheduled = kind === "arrivals" ? stop.scheduledArrival : stop.scheduledDeparture;
  if (scheduled === null) return null;
  const scheduledTime = Date.parse(scheduled);
  const headsign = normalized(snapshot.headsign);
  const candidates = movements.filter((movement) => movement.product.type === null
    || movement.product.type === undefined || movement.product.type === "TRAIN")
    .map((movement) => {
      const planned = Date.parse(movement.plannedDateTime);
      const difference = Math.abs(planned - scheduledTime);
      // Arrivals supply origin, not direction. Origin is not evidence for a destination
      // headsign; absent/empty text must not receive the substring bonus either.
      const direction = normalized(movement.direction);
      const directionScore = direction.length === 0 || headsign.length === 0 ? 0
        : direction === headsign ? 10 : direction.includes(headsign) || headsign.includes(direction) ? 5 : 0;
      return { movement, difference, score: productScore(snapshot, movement) + directionScore };
    })
    .filter((candidate) => candidate.difference <= 10 * 60_000 && candidate.score >= 15)
    .sort((left, right) => right.score - left.score || left.difference - right.difference);
  if (candidates.length === 0) return null;
  if (candidates.length > 1 && candidates[0]!.score === candidates[1]!.score
    && candidates[0]!.difference === candidates[1]!.difference) return null;
  return candidates[0]!.movement;
}

function fnv1a(value: string): string {
  let hash = 0x811c9dc5;
  for (const character of value) {
    hash ^= character.codePointAt(0) ?? 0;
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}

function messageIds(movement: NSMovement): string[] {
  return (movement.messages ?? []).flatMap((message) => {
    const text = message.message.trim();
    return text.length === 0 ? [] : [`ns:${fnv1a(`${message.style ?? ""}|${text}`)}`];
  });
}

export class NSRealtimeOverlay implements PlatformRealtimeOverlay {
  readonly sourceName = "NS Reisinformatie";
  readonly supportedCountryCodes = new Set(["NL"]);
  private stationsCache: { loadedAt: number; value: Promise<NSStation[]> } | null = null;
  private readonly movementCache = new ExpiringCache<Promise<NSMovement[]>>(200);
  private readonly enrichmentCache = new ExpiringCache<Promise<EnrichmentResult>>(500);

  constructor(
    private readonly subscriptionKey: string,
    private readonly baseURL = defaultBaseURL,
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
  ) {}

  // A separate lane preserves departures when the additional arrival board is
  // slow. Reuse the resolved departure's train number to avoid a category join.
  readonly arrivalOverlay: PlatformRealtimeOverlay = {
    sourceName: "NS Reisinformatie arrivals",
    supportedCountryCodes: this.supportedCountryCodes,
    platformUpdates: (snapshot) => this.intermediateArrivals(snapshot),
  };

  private async intermediateArrivals(snapshot: TripSnapshot): Promise<PlatformObservation[]> {
    const primary = await this.enrich(snapshot);
    const stations = await this.stations();
    const stops = snapshot.stops.filter((stop) => stop.scheduledArrival !== null
      && stop.scheduledDeparture !== null && primary.trainNumbers.has(stop.sequence));
    const results = await Promise.all(stops.map(async (stop): Promise<PlatformObservation | null> => {
      const station = matchingStation(stop, stations);
      if (station === null) return null;
      const trainNumber = primary.trainNumbers.get(stop.sequence)!;
      const movement = matchingMovement(stop, { ...snapshot, product: trainNumber },
        await this.movements(station.code, "arrivals"), "arrivals");
      const expectedArrival = iso(movement?.actualDateTime);
      if (expectedArrival === null) return null;
      return { stopSequence: stop.sequence, stationId: stop.stationId, expectedArrival,
        observedAt: this.now().toISOString(), source: this.sourceName };
    }));
    return results.filter((value): value is PlatformObservation => value !== null);
  }

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
    const stations = await this.stations();
    const candidates = realtimeCandidateStops(snapshot, (stop) => stop.countryCode === "NL", 2);
    const values = await Promise.all(candidates.map(async (stop) => {
      const station = matchingStation(stop, stations);
      if (station === null) return null;
      const kind = stop.scheduledDeparture === null ? "arrivals" : "departures";
      const movement = matchingMovement(stop, snapshot, await this.movements(station.code, kind), kind);
      if (movement === null) return null;
      const plannedPlatform = platform(movement.plannedTrack);
      const expectedPlatform = platform(movement.actualTrack) ?? plannedPlatform;
      const expectedTime = iso(movement.actualDateTime);
      return {
        observation: {
          stopSequence: stop.sequence,
          stationId: stop.stationId,
          plannedPlatform,
          expectedPlatform,
          expectedArrival: stop.scheduledDeparture === null ? expectedTime ?? undefined : undefined,
          expectedDeparture: stop.scheduledDeparture !== null ? expectedTime ?? undefined : undefined,
          cancelled: movement.cancelled,
          observedAt: this.now().toISOString(),
          source: this.sourceName,
        } satisfies PlatformObservation,
        alertIds: messageIds(movement),
        trainNumber: movement.product.number?.trim() || null,
      };
    }));
    return {
      observations: values.flatMap((candidate) => candidate === null ? [] : [candidate.observation]),
      alertIds: [...new Set(values.flatMap((candidate) => candidate?.alertIds ?? []))],
      trainNumbers: new Map(values.flatMap((candidate) => candidate?.trainNumber == null
        ? [] : [[candidate.observation.stopSequence, candidate.trainNumber]])),
    };
  }

  private stations(): Promise<NSStation[]> {
    const now = this.now().getTime();
    if (this.stationsCache !== null && now - this.stationsCache.loadedAt < 24 * 60 * 60_000) {
      return this.stationsCache.value;
    }
    const value = this.json<NSStationsResponse>("stations").then((response) => response.payload);
    this.stationsCache = { loadedAt: now, value };
    return value;
  }

  private movements(stationCode: string, kind: "arrivals" | "departures"): Promise<NSMovement[]> {
    const key = `${stationCode}:${kind}`;
    const now = this.now().getTime();
    return cachedLoad(this.movementCache, key, now, 20_000, () =>
      this.json<NSMovementsResponse>(`${kind}?station=${encodeURIComponent(stationCode)}&maxJourneys=40`)
        .then((response) => response.payload[kind] ?? []));
  }

  private async json<Response>(path: string): Promise<Response> {
    const response = await this.fetcher(new URL(path, `${this.baseURL}/`), {
      headers: {
        accept: "application/json",
        "Ocp-Apim-Subscription-Key": this.subscriptionKey,
        "user-agent": "TrainTracker/0.4 (+https://github.com/jaguirre2192)",
      },
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) throw new Error(`NS Reisinformatie returned ${response.status}`);
    return response.json() as Promise<Response>;
  }
}
