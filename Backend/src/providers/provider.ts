import type {
  BoardEntrySnapshot,
  BoardReference,
  DiscoveryScope,
  StationSnapshot,
} from "../domain/discovery.js";
import type { CanonicalTripReference, TripSnapshot } from "../domain/snapshot.js";
import { TripSnapshotEnricher } from "./platform-overlay.js";

export interface RailProvider {
  readonly source: CanonicalTripReference["source"];
  readonly discoveryScope: DiscoveryScope;
  searchStations(query: string): Promise<StationSnapshot[]>;
  fetchBoard(reference: BoardReference): Promise<BoardEntrySnapshot[]>;
  fetchTrip(reference: CanonicalTripReference): Promise<TripSnapshot>;
}

export class RailProviderNotFoundError extends Error {
  constructor(message = "Requested rail trip is unavailable") {
    super(message);
    this.name = "RailProviderNotFoundError";
  }
}

export class ProviderRegistry {
  private readonly providers = new Map<CanonicalTripReference["source"], RailProvider>();

  constructor(
    providers: RailProvider[],
    private readonly enricher = new TripSnapshotEnricher([]),
    private readonly waitUntil?: (work: Promise<unknown>) => void,
    private readonly stationSearchProviders?: readonly RailProvider[],
  ) {
    for (const provider of providers) this.providers.set(provider.source, provider);
  }

  provider(source: CanonicalTripReference["source"]): RailProvider {
    const provider = this.providers.get(source);
    if (provider === undefined) throw new Error(`No provider registered for ${source}`);
    return provider;
  }

  async fetchTrip(reference: CanonicalTripReference): Promise<TripSnapshot> {
    const warming = this.enricher.prefetch(reference);
    this.waitUntil?.(warming);
    const snapshot = await this.provider(reference.source).fetchTrip(reference);
    return this.enricher.enrich(snapshot);
  }

  async searchStations(scope: DiscoveryScope, query: string): Promise<StationSnapshot[]> {
    const providers = (this.stationSearchProviders ?? [...this.providers.values()]).filter(provider => provider.discoveryScope === scope);
    const results = await Promise.allSettled(providers.map((provider) => provider.searchStations(query)));
    if (results.length > 0 && results.every((result) => result.status === "rejected")) {
      throw new AggregateError(
        results.map((result) => result.status === "rejected" ? result.reason : null),
        `All ${scope} discovery providers failed`,
      );
    }
    const stations = results.flatMap((result) => result.status === "fulfilled" ? result.value : []);
    const unique = new Map(stations.map((station) => [station.id, station]));
    return [...unique.values()].slice(0, 20);
  }

  fetchBoard(reference: BoardReference): Promise<BoardEntrySnapshot[]> {
    return this.provider(reference.source).fetchBoard(reference);
  }
}
