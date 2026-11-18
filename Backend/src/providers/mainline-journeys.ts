import type { JourneySearchProvider, ProviderJourneySearchRequest } from "./journey-provider.js";
import { decodeRailPlaceId, encodeRailPlaceId } from "./rail-place-id.js";
import { SrbijaVozProvider } from "./srbijavoz-provider.js";
import { TransitousJourneyProvider } from "./transitous-journeys.js";
import { searchSrbijaVozStations } from "./srbijavoz-stations.js";

/** Prefer the current operator timetable on the verified Serbian corridor. */
export class MainlineJourneyProvider implements JourneySearchProvider {
  constructor(
    private readonly serbia: SrbijaVozProvider,
    private readonly transitous: JourneySearchProvider = new TransitousJourneyProvider(),
  ) {}

  metricProviderForPlaces(query: string): "transitous" | "multiple" {
    return searchSrbijaVozStations(query).length > 0 ? "multiple" : "transitous";
  }

  metricProviderForSearch(input: Pick<ProviderJourneySearchRequest, "originId" | "destinationId">): "transitous" | "srbijavoz" {
    return this.serbia.handlesPlace(decodeRailPlaceId(input.originId))
      && this.serbia.handlesPlace(decodeRailPlaceId(input.destinationId)) ? "srbijavoz" : "transitous";
  }

  async searchPlaces(query: string, limit: number) {
    const official = await this.serbia.searchPlaces(query, limit);
    let aggregate;
    try { aggregate = await this.transitous.searchPlaces(query, limit); }
    catch (error) { if (official.length > 0) return official; throw error; }
    if (official.length === 0) return aggregate;
    // Short queries must still find other countries. Suppress only the known
    // duplicate station identities whose current operator result is present.
    const others = aggregate.filter((place) => !this.serbia.handlesPlace(decodeRailPlaceId(place.id)));
    return [...official, ...others].slice(0, Math.max(0, Math.floor(limit)));
  }

  async searchJourneys(input: ProviderJourneySearchRequest) {
    const origin = decodeRailPlaceId(input.originId);
    const destination = decodeRailPlaceId(input.destinationId);
    if (this.serbia.handlesPlace(origin) && this.serbia.handlesPlace(destination)) {
      // Never fall back to the known outdated aggregate timetable on failure.
      return this.serbia.searchJourneys(input);
    }
    // A Serbian selection can still participate in an international search.
    return this.transitous.searchJourneys({
      ...input,
      originId: encodeRailPlaceId(this.serbia.toTransitousPlace(origin)),
      destinationId: encodeRailPlaceId(this.serbia.toTransitousPlace(destination)),
    });
  }
}
