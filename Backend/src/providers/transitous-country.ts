import { physicalCountryCode } from "./country-location.js";
import { evidencedStationCountryCode } from "./station-country-evidence.js";

interface TransitousCountryPlace {
  name?: string;
  stopId?: string | null;
  country?: string | null;
  lat: number;
  lon: number;
}

export function transitousPlaceCountryCode(place: TransitousCountryPlace): string {
  const explicit = typeof place.country === "string" ? place.country.trim().toUpperCase() : "";
  const prefix = place.stopId?.slice(0, 2).toUpperCase() ?? "";
  const fallback = /^[A-Z]{2}$/u.test(explicit) && explicit !== "XX" && explicit !== "EU"
    ? explicit : /^[A-Z]{2}$/u.test(prefix) ? prefix : "XX";
  // A foreign feed can repeat its publisher's country in each call. Station
  // evidence or an unambiguous polygon takes precedence; uncertain/unsupported
  // coordinates retain explicit metadata before falling back to the namespace.
  return evidencedStationCountryCode(place.name, place.lat, place.lon)
    ?? physicalCountryCode(fallback, place.lat, place.lon);
}
