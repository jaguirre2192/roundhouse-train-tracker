import { isTranswaRailDeparture } from "./transwa-stations.js";

interface TransitousScopedStation {
  id: string;
  country?: string | null;
}

interface TransitousScopedDeparture {
  tripId: string;
  routeLongName?: string | null;
}

function countryCode(value: TransitousScopedStation): string {
  return value.country?.toUpperCase() ?? value.id.slice(0, 2).toUpperCase();
}

/**
 * Transitous normalizes upstream feeds well, but some agencies label urban
 * commuter rail as REGIONAL_RAIL. Keep the app's international surface scoped
 * to full-size intercity/mainline services where the feed identity is known.
 */
export function isTrackableTransitousStation(value: TransitousScopedStation): boolean {
  const id = value.id.toLowerCase();
  switch (countryCode(value)) {
    case "CA":
      return id.startsWith("ca-viarail_");
    case "AU":
      return ["regional-trains", "interstate", "nsw-trains", "vline"].some((part) => id.includes(part));
    case "FR":
      return !id.includes("ile-de-france-mobilites") && !id.includes("idfm:");
    case "JP":
      return !id.startsWith("jp-tokyo-rail_");
    case "NZ":
      return false;
    default:
      return true;
  }
}

export function isTrackableTransitousDeparture(value: TransitousScopedDeparture): boolean {
  const id = value.tripId.toLowerCase();
  if (id.includes("_ca-") && !id.includes("_ca-viarail_")) return false;
  if (
    id.includes("_au-")
    && !["regional-trains", "interstate", "nsw-trains", "vline"].some((part) => id.includes(part))
    && !isTranswaRailDeparture(value.tripId, value.routeLongName)
  ) {
    return false;
  }
  if (id.includes("_jp-tokyo-rail_")) return false;
  if (id.includes("ile-de-france-mobilites") || id.includes("idfm:")) return false;
  if (id.includes("_nz-")) return false;

  // Thailand's open SRT data divides some through trains into short trip
  // segments. The full route name still carries the actual intercity service.
  if (id.includes("_th-") && (value.routeLongName?.trim().length ?? 0) === 0) return false;
  return true;
}
