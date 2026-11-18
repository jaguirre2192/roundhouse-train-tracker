import {
  isTrackableTransitousDeparture,
  isTrackableTransitousStation,
} from "./transitous-mainline-scope.js";
import type { TransitousLeg } from "./transitous-journey-types.js";

export type JourneyLegClassification = "rail" | "walk" | "prohibited";

const acceptedRailModes = new Set([
  "HIGHSPEED_RAIL",
  "LONG_DISTANCE",
  "NIGHT_RAIL",
  "REGIONAL_RAIL",
]);

// GTFS route type 2 is the generic railway type used by feeds such as Amtrak.
// Extended type 100 is also generic railway service, used by NSW regional trains.
// Mode, feed and regional-station checks below still exclude urban services.
const acceptedRouteTypes = new Set([2, 100, 101, 102, 103, 105, 106]);

function countryCode(stopId: string): string {
  const prefix = stopId.slice(0, 2);
  return /^[a-z]{2}$/iu.test(prefix) ? prefix.toUpperCase() : "XX";
}

export class JourneyMainlinePolicy {
  classify(leg: TransitousLeg): JourneyLegClassification {
    const mode = leg.mode.trim().toUpperCase();
    if (mode === "WALK") return "walk";
    if (!acceptedRailModes.has(mode) || leg.routeType === undefined
      || leg.routeType === null || !acceptedRouteTypes.has(leg.routeType)) {
      return "prohibited";
    }
    const tripId = leg.tripId?.trim();
    if (tripId !== undefined && tripId.length > 0) {
      const departure = leg.routeLongName === undefined
        ? { tripId }
        : { tripId, routeLongName: leg.routeLongName };
      if (!isTrackableTransitousDeparture(departure)) return "prohibited";
    }
    if (mode !== "REGIONAL_RAIL") return "rail";

    const fromId = leg.from.stopId?.trim();
    const toId = leg.to.stopId?.trim();
    if (fromId === undefined || fromId.length === 0 || toId === undefined || toId.length === 0) {
      return "prohibited";
    }
    if (tripId === undefined || tripId.length === 0) return "prohibited";
    if (!isTrackableTransitousStation({ id: fromId, country: countryCode(fromId) })) return "prohibited";
    if (!isTrackableTransitousStation({ id: toId, country: countryCode(toId) })) return "prohibited";
    return "rail";
  }
}

export const journeyMainlinePolicy = new JourneyMainlinePolicy();
