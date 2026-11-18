import type { CanonicalTripReference, TripSnapshot } from "../domain/snapshot.js";
import { zonedWallClockToUTC } from "./zoned-time.js";

export interface GolemioTripIdentity {
  gtfsTripId: string;
  originArrival: number;
}

export function golemioReferenceIdentity(reference: CanonicalTripReference): { gtfsTripId: string; nativeDeparture: number } | null {
  if (reference.source !== "transitous") return null;
  const match = reference.nativeId.match(/^(\d{4})(\d{2})(\d{2})_(\d{2}):(\d{2})_cz-PID_([\w.:-]{1,160})$/u);
  if (match === null || `${match[1]}-${match[2]}-${match[3]}` !== reference.serviceDate) return null;
  const year = Number(match[1]), month = Number(match[2]), day = Number(match[3]);
  const date = new Date(Date.UTC(year, month - 1, day));
  if (date.toISOString().slice(0, 10) !== reference.serviceDate) return null;
  const hour = Number(match[4]), minute = Number(match[5]);
  if (hour >= 48 || minute >= 60) return null;
  const normalizedDay = new Date(Date.UTC(year, month - 1, day + Math.floor(hour / 24)));
  const nativeDeparture = zonedWallClockToUTC("Europe/Prague", normalizedDay.getUTCFullYear(),
    normalizedDay.getUTCMonth() + 1, normalizedDay.getUTCDate(), hour % 24, minute);
  return { gtfsTripId: match[6]!, nativeDeparture };
}

/** Only the exact PID static trip and its complete selected run can identify GPS. */
export function golemioTripIdentity(snapshot: TripSnapshot): GolemioTripIdentity | null {
  if (!snapshot.stops.some((stop) => stop.countryCode === "CZ")) return null;
  const identity = golemioReferenceIdentity(snapshot);
  if (identity === null) return null;
  const first = snapshot.stops[0];
  if (first === undefined) return null;
  const departure = Date.parse(first.scheduledDeparture ?? first.scheduledArrival ?? "");
  const arrival = Date.parse(first.scheduledArrival ?? first.scheduledDeparture ?? "");
  if (!Number.isFinite(departure) || !Number.isFinite(arrival)
    || Math.abs(identity.nativeDeparture - departure) > 60_000) return null;
  return { gtfsTripId: identity.gtfsTripId, originArrival: arrival };
}

export function record(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown> : null;
}

export function providerTime(value: unknown): number | null {
  if (typeof value !== "string") return null;
  const match = value.match(/^(\d{4})-(\d{2})-(\d{2})T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,9})?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$/u);
  if (match === null) return null;
  const date = new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3])));
  if (date.toISOString().slice(0, 10) !== `${match[1]}-${match[2]}-${match[3]}`) return null;
  const time = Date.parse(value);
  return Number.isFinite(time) ? time : null;
}
