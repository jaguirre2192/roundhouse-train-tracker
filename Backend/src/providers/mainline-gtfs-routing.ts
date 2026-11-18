import type { BoardReference } from "../domain/discovery.js";
import type { CanonicalTripReference } from "../domain/snapshot.js";
import type { RailProvider } from "./provider.js";
import type { JourneySearchProvider, ProviderJourneySearchRequest } from "./journey-provider.js";
import { JourneyProviderUnavailableError } from "./journey-provider.js";
import { decodeRailPlaceId } from "./rail-place-id.js";
import { StaticGTFSProvider, gtfsCountryForNativeID } from "./mainline-gtfs-provider.js";

/** Extra server-owned namespaces travel through the shipped opaque provider contract. */
export class GTFSDiscoveryProvider implements RailProvider {
  readonly source = "transitous" as const;
  readonly discoveryScope = "international" as const;
  constructor(private readonly upstream: RailProvider, private readonly extras: StaticGTFSProvider[]) {}
  async searchStations(query: string) {
    const results = await Promise.allSettled([...this.extras,this.upstream].map(p => p.searchStations(query)));
    if (results.every(r => r.status === "rejected")) throw new Error("Rail station discovery unavailable");
    return results.flatMap((r,i) => r.status === "fulfilled" ? r.value.filter(station =>
      i < this.extras.length || !this.extras.some(provider => provider.country === station.countryCode.toUpperCase())) : []).slice(0,20);
  }
  private provider(nativeId: string): RailProvider {
    const country = gtfsCountryForNativeID(nativeId);
    return this.extras.find(p => p.country === country) ?? this.upstream;
  }
  fetchBoard(reference: BoardReference) { return this.provider(reference.nativeId).fetchBoard(reference); }
  fetchTrip(reference: CanonicalTripReference) { return this.provider(reference.nativeId).fetchTrip(reference); }
}

export class GTFSJourneyProvider implements JourneySearchProvider {
  constructor(private readonly upstream: JourneySearchProvider, private readonly extras: StaticGTFSProvider[]) {}
  async searchPlaces(query: string, limit: number) {
    const results = await Promise.allSettled([...this.extras,this.upstream].map(p => p.searchPlaces(query,limit)));
    if (results.every(r => r.status === "rejected")) throw new JourneyProviderUnavailableError();
    return results.flatMap(r => r.status === "fulfilled" ? r.value : []).slice(0,limit);
  }
  searchJourneys(input: ProviderJourneySearchRequest) {
    const from = decodeRailPlaceId(input.originId), to = decodeRailPlaceId(input.destinationId);
    const extra = this.extras.find(p => p.handlesPlace(from) && p.handlesPlace(to));
    if (extra) return extra.searchJourneys(input);
    if (this.extras.some(p => p.handlesPlace(from) || p.handlesPlace(to))) {
      throw new JourneyProviderUnavailableError("No published through itinerary connects the selected rail networks");
    }
    return this.upstream.searchJourneys(input);
  }
}
