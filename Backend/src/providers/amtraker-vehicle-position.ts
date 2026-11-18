import type { TripSnapshot, VehiclePositionSnapshot } from "../domain/snapshot.js";
import { amtrakerPosition, type AmtrakerResponse, type AmtrakerTrain } from "./amtraker.js";
import { matchedAmtrakerStops, matchingAmtrakerTrain } from "./amtraker-stop-identity.js";
import { amtrakerStopEvidence, amtrakerStopObservation } from "./amtraker-stop-observation.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";
import type { TripPositionOverlay } from "./trip-position-overlay.js";

/** Amtrak trains saved from journey search carry Transitous identities (`…_us-Amtrak_…`) and no GPS. */
export function isAmtrakSnapshot(snapshot: TripSnapshot): boolean {
  return snapshot.source !== "amtraker"
    && (/amtrak/iu.test(snapshot.operatorName) || /us-amtrak/iu.test(snapshot.nativeId));
}

export function amtrakTrainNumber(snapshot: TripSnapshot): string | null {
  const tokens = snapshot.product.split(/[^A-Za-z0-9]+/u).filter(Boolean);
  const number = [...tokens].reverse().find((token) => /^\d{1,4}$/u.test(token));
  return number ?? null;
}

/**
 * Adds matched Amtraker timings, explicit stop events and GPS to imported Amtrak trips.
 * Timing and position use one cache and fetch; missing GPS never suppresses stop updates.
 */
export class AmtrakerVehiclePositionOverlay implements TripPositionOverlay, PlatformRealtimeOverlay {
  readonly sourceName = "Amtraker";
  readonly supportedCountryCodes = new Set(["US"]);
  private readonly cached = new Map<string, { loadedAt: number; value: AmtrakerResponse }>();
  private readonly pending = new Map<string, Promise<AmtrakerResponse>>();

  constructor(
    private readonly baseUrl = "https://api.amtraker.com/v3",
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
  ) {}

  async positionUpdates(snapshot: TripSnapshot): Promise<VehiclePositionSnapshot[]> {
    const train = await this.matchedTrain(snapshot);
    return train === null ? [] : amtrakerPosition(train, this.now());
  }

  async platformUpdates(snapshot: TripSnapshot): Promise<PlatformObservation[]> {
    const train = await this.matchedTrain(snapshot);
    if (train === null) return [];
    return matchedAmtrakerStops(snapshot, train).flatMap(({ saved, reported }) => {
      const evidence = amtrakerStopEvidence(reported, train, this.now());
      const observedAt = amtrakerStopObservation(undefined, train, this.now())
        ?? evidence.passageObservedAt ?? evidence.arrivalObservedAt;
      if (observedAt === undefined) return [];
      const arrival = reported.arr == null ? Number.NaN : Date.parse(reported.arr);
      const departure = reported.dep == null ? Number.NaN : Date.parse(reported.dep);
      const platform = reported.platform?.trim();
      return [{ stopSequence: saved.sequence, stationId: saved.stationId, observedAt, source: "Amtraker",
        ...(Number.isFinite(arrival) ? { expectedArrival: new Date(arrival).toISOString() } : {}),
        ...(Number.isFinite(departure) ? { expectedDeparture: new Date(departure).toISOString() } : {}),
        ...(platform ? { expectedPlatform: platform } : {}),
        ...(reported.status?.toLowerCase().includes("cancel") ? { cancelled: true } : {}),
        ...evidence }];
    });
  }

  private async matchedTrain(snapshot: TripSnapshot): Promise<AmtrakerTrain | null> {
    if (!isAmtrakSnapshot(snapshot)) return null;
    const number = amtrakTrainNumber(snapshot);
    if (number === null) return null;
    const payload = await this.trains(number);
    return matchingAmtrakerTrain(snapshot, Object.values(payload).flat().filter((train) => train.trainNum === number));
  }

  private async trains(number: string): Promise<AmtrakerResponse> {
    const now = this.now().getTime();
    const cached = this.cached.get(number);
    if (cached !== undefined && now - cached.loadedAt < 20_000) return cached.value;
    const pending = this.pending.get(number);
    if (pending !== undefined) return pending;
    const request = this.loadTrains(number);
    this.pending.set(number, request);
    try { return await request; } finally { this.pending.delete(number); }
  }

  private async loadTrains(number: string): Promise<AmtrakerResponse> {
    const response = await this.fetcher(`${this.baseUrl}/trains/${encodeURIComponent(number)}`, {
      headers: { accept: "application/json", "user-agent": "TrainTrackerWatcher/0.3" },
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) throw new Error(`Amtraker returned ${response.status}`);
    const value = await response.json() as AmtrakerResponse;
    this.cached.set(number, { loadedAt: this.now().getTime(), value });
    return value;
  }
}
