import { realtimeCandidateStops } from "./realtime-stop-candidates.js";
import type { TripSnapshot, VehiclePositionSnapshot } from "../domain/snapshot.js";
import { cachedLoad, ExpiringCache } from "./expiring-cache.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";
import type { TripPositionOverlay } from "./trip-position-overlay.js";
import {
  irishRailObservations,
  irishRailStationForStop,
  matchingIrishRailBoardRow,
  matchingIrishRailRun,
} from "./irish-rail-mapper.js";
import {
  parseIrishRailBoard,
  parseIrishRailMovements,
  parseIrishRailRuns,
  parseIrishRailStations,
} from "./irish-rail-xml.js";

const defaultBaseURL = "https://api.irishrail.ie/realtime/realtime.asmx";

interface Enrichment {
  observations: PlatformObservation[];
  trainCode: string | null;
}

export class IrishRailRealtimeOverlay implements PlatformRealtimeOverlay, TripPositionOverlay {
  readonly sourceName = "Irish Rail Realtime API";
  readonly supportedCountryCodes = new Set(["IE"]);
  private readonly responseCache = new Map<string, { loadedAt: number; value: Promise<string> }>();
  private readonly enrichmentCache = new ExpiringCache<Promise<Enrichment>>(500);

  constructor(
    private readonly baseURL = defaultBaseURL,
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
  ) {}

  async platformUpdates(snapshot: TripSnapshot): Promise<PlatformObservation[]> {
    return (await this.enrich(snapshot)).observations;
  }

  async positionUpdates(_snapshot: TripSnapshot): Promise<VehiclePositionSnapshot[]> {
    // getHaconTrainsXML supplies coordinates but no position observation time.
    // Query/server time and TrainOriginTime describe retrieval or the timetable,
    // not the age of that point. The native evidence model treats every recent
    // real point as GPS/passage proof, so withhold undated points entirely.
    // Expected times continue through the separate movement overlay below.
    return [];
  }

  private enrich(snapshot: TripSnapshot): Promise<Enrichment> {
    const now = this.now().getTime();
    return cachedLoad(this.enrichmentCache, snapshot.id, now, 20_000, () => this.loadEnrichment(snapshot));
  }

  private async loadEnrichment(snapshot: TripSnapshot): Promise<Enrichment> {
    const stations = parseIrishRailStations(await this.request("getAllStationsXML", {}, 24 * 60 * 60_000));
    const runs = parseIrishRailRuns(await this.request("getHaconTrainsXML", {}, 20_000));
    const run = matchingIrishRailRun(snapshot, stations, runs);
    const candidateStops = realtimeCandidateStops(snapshot, (stop) => stop.countryCode === "IE", 3);
    const boards = run === null ? await Promise.all(candidateStops.map(async (stop) => {
      const station = irishRailStationForStop(stop, stations);
      if (station === null) return [];
      const xml = await this.request("getStationDataByCodeXML_WithNumMins", {
        StationCode: station.code,
        NumMins: "90",
      }, 20_000);
      return parseIrishRailBoard(xml).map((row) => ({ row, stop }));
    })) : [];
    const row = run === null ? matchingIrishRailBoardRow(snapshot, boards.flat()) : null;
    const trainCode = run?.trainCode ?? row?.trainCode ?? null;
    const trainDate = run?.trainDate ?? row?.trainDate ?? null;
    const status = run?.status ?? row?.status ?? "";
    if (trainCode === null || trainDate === null) return { observations: [], trainCode: null };
    const movementXML = await this.request("getTrainMovementsXML", {
      TrainId: trainCode,
      TrainDate: trainDate,
    }, 20_000);
    return {
      observations: irishRailObservations(
        snapshot,
        parseIrishRailMovements(movementXML),
        status,
        this.now().toISOString(),
      ),
      trainCode,
    };
  }

  private request(endpoint: string, parameters: Record<string, string>, ttl: number): Promise<string> {
    const url = new URL(`${this.baseURL.replace(/\/$/u, "")}/${endpoint}`);
    url.search = new URLSearchParams(parameters).toString();
    const key = url.toString();
    const now = this.now().getTime();
    const cached = this.responseCache.get(key);
    if (cached !== undefined && now - cached.loadedAt < ttl) return cached.value;
    const value = this.load(url).catch((error) => {
      this.responseCache.delete(key);
      throw error;
    });
    this.responseCache.set(key, { loadedAt: now, value });
    return value;
  }

  private async load(url: URL): Promise<string> {
    const response = await this.fetcher(url, {
      headers: {
        accept: "application/xml",
        "user-agent": "TrainTracker/0.3 (+https://github.com/jaguirre2192)",
      },
      signal: AbortSignal.timeout(8_000),
    });
    if (!response.ok) throw new Error(`Irish Rail Realtime API returned ${response.status}`);
    return response.text();
  }
}
