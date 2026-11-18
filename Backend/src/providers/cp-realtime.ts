import { createHash } from "node:crypto";
import type { StopSnapshot, TripSnapshot, VehiclePositionSnapshot } from "../domain/snapshot.js";
import { cachedLoad, ExpiringCache } from "./expiring-cache.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";
import type { TripPositionOverlay } from "./trip-position-overlay.js";

interface CpStation {
  code: string;
  designation: string;
}

interface CpTrainStop {
  station: CpStation;
  arrival?: string | null;
  departure?: string | null;
  platform?: string | number | null;
  delay?: string | number | null;
  supression?: boolean | string | number | null;
  ETA?: string | null;
  ETD?: string | null;
}

interface CpTrain {
  trainNumber: string | number;
  delay?: string | number | null;
  latitude?: string | number | null;
  longitude?: string | number | null;
  hasDisruptions?: boolean | null;
  messages?: unknown[] | null;
  trainStops: CpTrainStop[];
}

function trainNumber(snapshot: TripSnapshot): string | null {
  const cpId = snapshot.nativeId.match(/pt-Comboios-de-Portugal\(CP\)_([0-9]{1,6})_/iu)?.[1];
  if (cpId !== undefined) return cpId;
  const product = snapshot.product.match(/\b([0-9]{1,6})\b/u)?.[1];
  return product ?? null;
}

function stationTokens(value: string): Set<string> {
  return new Set(value.match(/\d+/gu) ?? []);
}

function matchingStop(code: string, snapshot: TripSnapshot): StopSnapshot | undefined {
  const target = stationTokens(code);
  return snapshot.stops.find((stop) => {
    const candidate = stationTokens(stop.stationId);
    return target.size > 0 && [...target].every((token) => candidate.has(token));
  });
}

function minutes(value: string | null | undefined): number | null {
  const match = value?.match(/^(\d{1,2}):(\d{2})$/u);
  if (match === null || match === undefined) return null;
  const hour = Number(match[1]);
  const minute = Number(match[2]);
  return hour <= 23 && minute <= 59 ? hour * 60 + minute : null;
}

function differenceMinutes(expected: string | null | undefined, scheduled: string | null | undefined): number | null {
  const expectedMinutes = minutes(expected);
  const scheduledMinutes = minutes(scheduled);
  if (expectedMinutes === null || scheduledMinutes === null) return null;
  let difference = expectedMinutes - scheduledMinutes;
  if (difference > 12 * 60) difference -= 24 * 60;
  if (difference < -12 * 60) difference += 24 * 60;
  return difference;
}

// CP sends null for "no realtime data"; Number(null) === 0 would read that as on time
// or as a train at (0, 0).
function finiteNumber(value: string | number | null | undefined): number | null {
  if (value === null || value === undefined) return null;
  if (typeof value === "string" && value.trim().length === 0) return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function position(train: CpTrain): { latitude: number; longitude: number } | null {
  const latitude = finiteNumber(train.latitude);
  const longitude = finiteNumber(train.longitude);
  if (latitude === null || longitude === null) return null;
  if (Math.abs(latitude) > 90 || Math.abs(longitude) > 180) return null;
  if (latitude === 0 && longitude === 0) return null;
  return { latitude, longitude };
}

function shifted(scheduled: string | null, deltaMinutes: number | null): string | null | undefined {
  if (scheduled === null || deltaMinutes === null) return undefined;
  const epoch = Date.parse(scheduled);
  return Number.isFinite(epoch) ? new Date(epoch + deltaMinutes * 60_000).toISOString() : undefined;
}

function expectedTime(
  expected: string | null | undefined,
  cpScheduled: string | null | undefined,
  canonicalScheduled: string | null,
  delay: string | number | null | undefined,
): string | null | undefined {
  const eventDifference = differenceMinutes(expected, cpScheduled);
  if (eventDifference !== null) return shifted(canonicalScheduled, eventDifference);
  return shifted(canonicalScheduled, finiteNumber(delay));
}

function cancelled(value: CpTrainStop["supression"]): boolean {
  if (typeof value === "boolean") return value;
  if (typeof value === "number") return value !== 0;
  return value !== null && value !== undefined && ["1", "true", "yes", "sim", "suppressed"]
    .includes(value.trim().toLowerCase());
}

function alertIds(train: CpTrain, number: string, serviceDate: string): string[] {
  if (train.hasDisruptions !== true && (train.messages?.length ?? 0) === 0) return [];
  const payloads = train.messages?.length === 0 || train.messages === null || train.messages === undefined
    ? ["disruption"]
    : train.messages;
  return payloads.map((message) => {
    const digest = createHash("sha256").update(JSON.stringify(message)).digest("hex").slice(0, 16);
    return `cp-alert-${number}-${serviceDate}-${digest}`;
  });
}

export class CpRealtimeOverlay implements PlatformRealtimeOverlay, TripPositionOverlay {
  readonly sourceName = "CP official realtime";
  readonly supportedCountryCodes = new Set(["PT"]);
  private readonly cache = new ExpiringCache<Promise<{ loadedAt: string; value: CpTrain }>>(200);

  constructor(
    private readonly apiKey: string,
    private readonly connectId: string,
    private readonly connectSecret: string,
    private readonly baseUrl = "https://api-gateway.cp.pt/cp/services/travel-api",
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
  ) {}

  async platformUpdates(snapshot: TripSnapshot): Promise<PlatformObservation[]> {
    const number = trainNumber(snapshot);
    if (number === null) return [];
    // The CP payload carries no observation timestamp; the fetch time is the closest
    // source-side time, and unlike now() it does not drift forward while cached.
    const { loadedAt: observedAt, value: train } = await this.train(number, snapshot.serviceDate);
    return train.trainStops.flatMap((value): PlatformObservation[] => {
      const stop = matchingStop(value.station.code, snapshot);
      if (stop === undefined) return [];
      const expectedPlatform = value.platform === null || value.platform === undefined
        ? undefined
        : String(value.platform).trim();
      const stopCancelled = cancelled(value.supression);
      const delay = finiteNumber(value.delay) ?? finiteNumber(train.delay);
      const expectedArrival = expectedTime(value.ETA, value.arrival, stop.scheduledArrival, delay);
      const expectedDeparture = expectedTime(value.ETD, value.departure, stop.scheduledDeparture, delay);
      if (
        (expectedPlatform === undefined || expectedPlatform.length === 0)
        && expectedArrival === undefined
        && expectedDeparture === undefined
        && !stopCancelled
      ) return [];
      return [{
        stopSequence: stop.sequence,
        stationId: stop.stationId,
        plannedPlatform: stop.plannedPlatform ?? expectedPlatform,
        expectedPlatform,
        expectedArrival,
        expectedDeparture,
        cancelled: stopCancelled,
        observedAt,
        source: this.sourceName,
      }];
    });
  }

  async tripAlertIds(snapshot: TripSnapshot): Promise<string[]> {
    const number = trainNumber(snapshot);
    if (number === null) return [];
    return alertIds((await this.train(number, snapshot.serviceDate)).value, number, snapshot.serviceDate);
  }

  async positionUpdates(snapshot: TripSnapshot): Promise<VehiclePositionSnapshot[]> {
    const number = trainNumber(snapshot);
    if (number === null) return [];
    const { loadedAt, value: train } = await this.train(number, snapshot.serviceDate);
    const coordinates = position(train);
    if (coordinates === null) return [];
    return [{
      ...coordinates,
      heading: null,
      source: "real",
      confidence: 0.9,
      asOf: loadedAt,
      provider: this.sourceName,
    }];
  }

  private train(number: string, serviceDate: string): Promise<{ loadedAt: string; value: CpTrain }> {
    const now = this.now();
    return cachedLoad(this.cache, `${number}:${serviceDate}`, now.getTime(), 15_000, async () => ({
      loadedAt: now.toISOString(),
      value: await this.load(number, serviceDate),
    }));
  }

  private async load(number: string, serviceDate: string): Promise<CpTrain> {
    const response = await this.fetcher(`${this.baseUrl}/trains/${encodeURIComponent(number)}/timetable/${serviceDate}`, {
      headers: {
        accept: "application/json",
        "user-agent": "TrainTracker/0.3 (+https://github.com/jaguirre2192)",
        "x-api-key": this.apiKey,
        "x-cp-connect-id": this.connectId,
        "x-cp-connect-secret": this.connectSecret,
      },
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) throw new Error(`CP official realtime returned ${response.status}`);
    return await response.json() as CpTrain;
  }
}
