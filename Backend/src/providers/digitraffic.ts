import { realtimeCandidateStops } from "./realtime-stop-candidates.js";
import type { TripSnapshot, VehiclePositionSnapshot } from "../domain/snapshot.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";
import type { TripPositionOverlay } from "./trip-position-overlay.js";
import { cachedLoad, ExpiringCache } from "./expiring-cache.js";
import { digitrafficObservation, digitrafficStation, digitrafficTrain } from "./digitraffic-matching.js";
import type { DigitrafficStation, DigitrafficTrain } from "./digitraffic-matching.js";
import { digitrafficPassengerAlertIds, type DigitrafficPassengerCall, type DigitrafficPassengerMessage } from "./digitraffic-passenger-alerts.js";
import { digitrafficPosition } from "./digitraffic-position.js";
import type { DigitrafficLocation } from "./digitraffic-position.js";

interface Enrichment {
  observations: PlatformObservation[];
  train: DigitrafficTrain | null;
  passengerCalls: DigitrafficPassengerCall[];
}

export class DigitrafficPlatformOverlay implements PlatformRealtimeOverlay, TripPositionOverlay {
  readonly sourceName = "Fintraffic Digitraffic";
  readonly supportedCountryCodes = new Set(["FI"]);
  private readonly stationCache = new ExpiringCache<Promise<DigitrafficStation[]>>(1);
  private readonly boardCache = new ExpiringCache<Promise<DigitrafficTrain[]>>(200);
  private readonly enrichmentCache = new ExpiringCache<Promise<Enrichment>>(500);
  private readonly passengerCache = new ExpiringCache<Promise<DigitrafficPassengerMessage[]>>(200);
  private readonly locationCache = new ExpiringCache<Promise<DigitrafficLocation[]>>(1);

  constructor(
    private readonly baseUrl = "https://rata.digitraffic.fi/api/v1",
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
  ) {}

  async platformUpdates(snapshot: TripSnapshot): Promise<PlatformObservation[]> {
    return (await this.enrich(snapshot)).observations;
  }

  async positionUpdates(snapshot: TripSnapshot): Promise<VehiclePositionSnapshot[]> {
    const train = (await this.enrich(snapshot)).train;
    if (train === null) return [];
    const locations = await cachedLoad(this.locationCache, "latest", this.now().getTime(), 10_000, () =>
      this.json<DigitrafficLocation[]>("train-locations/latest/"));
    return digitrafficPosition(train, locations, this.now(), this.sourceName);
  }

  async tripAlertIds(snapshot: TripSnapshot): Promise<string[]> {
    const { train, passengerCalls } = await this.enrich(snapshot);
    if (train === null || passengerCalls.length === 0) return [];
    const query = new URLSearchParams({ train_number: String(train.trainNumber), train_departure_date: train.departureDate });
    const messages = await cachedLoad(this.passengerCache, `${train.departureDate}:${train.trainNumber}`,
      this.now().getTime(), 30_000, () => this.json<DigitrafficPassengerMessage[]>(`passenger-information/active?${query}`));
    return digitrafficPassengerAlertIds(train, passengerCalls, Array.isArray(messages) ? messages : [], this.now().getTime());
  }

  private enrich(snapshot: TripSnapshot): Promise<Enrichment> {
    return cachedLoad(this.enrichmentCache, snapshot.id, this.now().getTime(), 15_000, () => this.load(snapshot));
  }

  private async load(snapshot: TripSnapshot): Promise<Enrichment> {
    const stations = await cachedLoad(this.stationCache, "stations", this.now().getTime(), 24 * 60 * 60_000, async () =>
      (await this.json<DigitrafficStation[]>("metadata/stations")).filter((station) => station.passengerTraffic));
    const candidates = realtimeCandidateStops(snapshot, (stop) => stop.countryCode === "FI", 2);
    const values = await Promise.all(candidates.map(async (stop) => {
      const station = digitrafficStation(stop, stations);
      if (station === undefined) return null;
      const trains = await cachedLoad(this.boardCache, station.stationShortCode, this.now().getTime(), 20_000, () =>
        this.json<DigitrafficTrain[]>(`live-trains/station/${encodeURIComponent(station.stationShortCode)}?${new URLSearchParams({
          arrived_trains: "5", arriving_trains: "20", departed_trains: "5", departing_trains: "20",
          include_nonstopping: "false", train_categories: "Commuter,Long-distance",
        })}`));
      const train = digitrafficTrain(stop, snapshot, station.stationShortCode, trains);
      return train === undefined ? null : {
        train,
        observation: digitrafficObservation(stop, station.stationShortCode, train, this.now().toISOString(), this.sourceName),
      };
    }));
    const matched = values.flatMap((value) => value === null ? [] : [value]);
    const identities = new Set(matched.map(({ train }) => `${train.departureDate}:${train.trainNumber}`));
    // Conflicting anchor matches cannot identify a vehicle or contribute delays.
    if (identities.size !== 1) return { observations: [], train: null, passengerCalls: [] };
    const train = matched[0]!.train;
    const observedAt = this.now().toISOString();
    // Station boards return the complete identified train. Reuse those rows for
    // the whole route instead of limiting the information to request anchors.
    const observations = snapshot.stops.filter((stop) => stop.countryCode === "FI").flatMap((stop) => {
      const station = digitrafficStation(stop, stations);
      if (station === undefined) return [];
      const observation = digitrafficObservation(stop, station.stationShortCode, train, observedAt, this.sourceName);
      return observation === null ? [] : [observation];
    });
    const passengerCalls = snapshot.stops.filter(stop => stop.countryCode === "FI").flatMap(stop => {
      const station = digitrafficStation(stop, stations);
      const times = [stop.scheduledArrival, stop.scheduledDeparture, stop.expectedArrival, stop.expectedDeparture]
        .map(value => Date.parse(value ?? "")).filter(Number.isFinite);
      return station === undefined || times.length === 0 ? [] : [{
        stationShortCode: station.stationShortCode, from: Math.min(...times), to: Math.max(...times),
      }];
    });
    return { observations, train, passengerCalls };
  }

  private async json<T>(path: string): Promise<T> {
    const response = await this.fetcher(new URL(path, `${this.baseUrl}/`), {
      headers: { accept: "application/json", "accept-encoding": "gzip", "digitraffic-user": "TrainTracker/0.2" },
      signal: AbortSignal.timeout(8_000),
    });
    if (!response.ok) throw new Error(`Digitraffic returned ${response.status}`);
    return response.json() as Promise<T>;
  }
}
