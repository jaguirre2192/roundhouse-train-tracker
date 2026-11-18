import type { CanonicalTripReference, ProviderSource, StopSnapshot } from "./snapshot.js";

export type DiscoveryScope = "us" | "international";
export type BoardDirection = "arrivals" | "departures";

export interface StationSnapshot {
  id: string;
  source: ProviderSource;
  nativeId: string;
  name: string;
  countryCode: string;
  latitude: number;
  longitude: number;
  operatorHints: string[];
}

export interface BoardReference {
  stationId: string;
  source: ProviderSource;
  nativeId: string;
  at: string;
  direction: BoardDirection;
}

export interface BoardEntrySnapshot {
  trip: CanonicalTripReference;
  stop: StopSnapshot;
  headsign: string;
  product: string;
}
