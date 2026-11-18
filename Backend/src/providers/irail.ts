import { cachedLoad, ExpiringCache } from "./expiring-cache.js";
import { realtimeCandidateStops } from "./realtime-stop-candidates.js";
import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";

interface IRailDeparture {
  time: string;
  delay?: string | null;
  canceled?: string | null;
  vehicle?: string | null;
  vehicleinfo?: { shortname?: string | null; number?: string | null } | null;
  platform?: string | null;
}

function truthy(value: string | null | undefined): boolean {
  return value === "1" || value?.toLowerCase() === "true";
}

function expectedDeparture(departure: IRailDeparture): string | null {
  const epoch = Number(departure.time) * 1_000;
  const delay = Number(departure.delay ?? 0) * 1_000;
  return Number.isFinite(epoch) && Number.isFinite(delay) ? new Date(epoch + delay).toISOString() : null;
}

interface IRailBoard {
  timestamp: string;
  departures?: { departure?: IRailDeparture[] };
  arrivals?: { arrival?: IRailDeparture[] };
}

function normalized(value: string | null | undefined): string | null {
  const result = value?.trim();
  return result === undefined || result.length === 0 || result === "?" ? null : result;
}

function numericTokens(value: string, minimumLength = 2): Set<string> {
  return new Set(value.split(/\D+/u).filter((token) => token.length >= minimumLength));
}

function scheduledTime(stop: StopSnapshot): number | null {
  const value = stop.scheduledDeparture ?? stop.scheduledArrival;
  if (value === null) return null;
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? null : parsed;
}

function matchingDeparture(stop: StopSnapshot, snapshot: TripSnapshot, departures: IRailDeparture[]): IRailDeparture | undefined {
  const tripNumbers = numericTokens(snapshot.product);
  const scheduled = scheduledTime(stop);
  return departures
    .filter((departure) => {
      const identifiers = [departure.vehicle, departure.vehicleinfo?.shortname, departure.vehicleinfo?.number]
        .filter((value): value is string => value !== null && value !== undefined)
        .join(" ");
      if ([...tripNumbers].every((token) => !numericTokens(identifiers).has(token))) return false;
      if (scheduled === null) return true;
      const departureTime = Number(departure.time) * 1_000;
      return Number.isFinite(departureTime) && Math.abs(departureTime - scheduled) < 45 * 60_000;
    })
    .sort((left, right) => {
      if (scheduled === null) return 0;
      return Math.abs(Number(left.time) * 1_000 - scheduled) - Math.abs(Number(right.time) * 1_000 - scheduled);
    })[0];
}

export class IRailPlatformOverlay implements PlatformRealtimeOverlay {
  readonly sourceName = "iRail";
  readonly supportedCountryCodes = new Set(["BE"]);
  private readonly boardCache = new ExpiringCache<Promise<IRailBoard>>(200);

  constructor(
    private readonly baseUrl = "https://api.irail.be/v1",
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
  ) {}

  async platformUpdates(snapshot: TripSnapshot): Promise<PlatformObservation[]> {
    const candidates = realtimeCandidateStops(snapshot, (stop) => stop.countryCode === "BE", 2);
    const results = await Promise.all(candidates.map(async (stop): Promise<PlatformObservation | null> => {
      const kind = stop.scheduledDeparture === null ? "arrival" : "departure";
      const board = await this.board(stop.stationName, kind);
      const movements = kind === "arrival" ? board.arrivals?.arrival ?? [] : board.departures?.departure ?? [];
      const departure = matchingDeparture(stop, snapshot, movements);
      if (departure === undefined) return null;
      const platform = normalized(departure?.platform);
      const hasRealtime = departure.delay !== null && departure.delay !== undefined;
      const cancelled = truthy(departure.canceled);
      if (platform === null && !hasRealtime && !cancelled) return null;
      const epoch = Number(board.timestamp) * 1_000;
      return {
        stopSequence: stop.sequence,
        stationId: stop.stationId,
        plannedPlatform: stop.plannedPlatform,
        expectedPlatform: platform,
        expectedArrival: kind === "arrival" && hasRealtime ? expectedDeparture(departure) : undefined,
        expectedDeparture: kind === "departure" && hasRealtime ? expectedDeparture(departure) : undefined,
        cancelled,
        observedAt: Number.isFinite(epoch) ? new Date(epoch).toISOString() : this.now().toISOString(),
        source: this.sourceName,
      };
    }));
    return results.filter((value): value is PlatformObservation => value !== null);
  }

  private board(station: string, kind: "arrival" | "departure"): Promise<IRailBoard> {
    return cachedLoad(this.boardCache, `${station}:${kind}`, this.now().getTime(), 20_000, async () => {
      const url = new URL("liveboard/", this.baseUrl.endsWith("/") ? this.baseUrl : `${this.baseUrl}/`);
      url.search = new URLSearchParams({ station, arrdep: kind, format: "json", lang: "en" }).toString();
      const response = await this.fetcher(url, {
        headers: { accept: "application/json", "user-agent": "TrainTracker/0.2 (+https://github.com/jaguirre2192)" },
        signal: AbortSignal.timeout(8_000),
      });
      if (!response.ok) throw new Error(`iRail returned ${response.status}`);
      return response.json() as Promise<IRailBoard>;
    });
  }
}
