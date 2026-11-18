import { zonedParts } from "./zoned-time.js";

interface ServiceDatePlace {
  scheduledDeparture?: string | null | undefined;
  scheduledArrival?: string | null | undefined;
  departure?: string | null | undefined;
  arrival?: string | null | undefined;
  tz?: string | null | undefined;
}

function normalized(value: string | null | undefined): string | null {
  const result = value?.trim();
  return result === undefined || result.length === 0 ? null : result;
}

function isoDate(year: number, month: number, day: number): string {
  return `${String(year).padStart(4, "0")}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
}

function localDate(timestamp: string | null | undefined, timeZone: string | null | undefined): string | null {
  const milliseconds = Date.parse(timestamp ?? "");
  if (!Number.isFinite(milliseconds)) return null;
  const zone = normalized(timeZone);
  if (zone === null) return new Date(milliseconds).toISOString().slice(0, 10);
  try {
    const parts = zonedParts(milliseconds, zone);
    return isoDate(parts.year, parts.month, parts.day);
  } catch {
    return new Date(milliseconds).toISOString().slice(0, 10);
  }
}

// The service date realtime feeds key on (GTFS start_date, CP/IP/Irish Rail origin
// date, SIRI DataFrameRef) is the day the train left its origin, in local time. MOTIS
// trip ids start with exactly that ("20260721_21:04_fr-..."), so an overnight train
// boarded after midnight keeps its departure day. Without a usable id, fall back to
// the given stop's own local date rather than the UTC date of its timestamp.
export function transitousServiceDate(
  tripId: string | null | undefined,
  place: ServiceDatePlace,
  fallback: string,
): string {
  const timestamp = normalized(place.scheduledDeparture) ?? normalized(place.scheduledArrival)
    ?? normalized(place.departure) ?? normalized(place.arrival);
  const placeDate = localDate(timestamp, place.tz);
  const match = tripId?.match(/^(\d{4})(\d{2})(\d{2})_/u);
  if (match !== null && match !== undefined) {
    const day = new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3])));
    const value = isoDate(day.getUTCFullYear(), day.getUTCMonth() + 1, day.getUTCDate());
    const valid = value === `${match[1]}-${match[2]}-${match[3]}`;
    // A train reaches the boarding stop on its origin day or up to a few days later;
    // one day of slack covers a westward time-zone crossing just after midnight.
    const elapsed = placeDate === null ? 0 : Date.parse(placeDate) - day.getTime();
    const plausible = elapsed >= -86_400_000 && elapsed <= 3 * 86_400_000;
    if (valid && plausible) return value;
  }
  return placeDate ?? fallback.slice(0, 10);
}
