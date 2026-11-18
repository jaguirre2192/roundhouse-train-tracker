import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import type { RegionalRailCall, RegionalRailIndex, RegionalRailStation, RegionalRailTrip } from "./trafiklab-regional-index.js";

const stockholm = new Intl.DateTimeFormat("sv-SE", {
  timeZone: "Europe/Stockholm", year: "numeric", month: "2-digit", day: "2-digit",
  hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
});

export interface RegionalRailMatch {
  trip: RegionalRailTrip;
  calls: ReadonlyMap<number, RegionalRailCall>;
}

function serviceSeconds(value: string | null, date: string): number | null {
  if (value === null || !Number.isFinite(Date.parse(value))) return null;
  const parts = Object.fromEntries(stockholm.formatToParts(new Date(value)).map((part) => [part.type, part.value]));
  const day = Date.parse(`${parts.year}-${parts.month}-${parts.day}T00:00:00Z`);
  const serviceDay = Date.parse(`${date}T00:00:00Z`);
  return (day - serviceDay) / 1_000 + Number(parts.hour) * 3_600 + Number(parts.minute) * 60 + Number(parts.second);
}

function stationName(value: string): string {
  const normalized = value.toLowerCase().normalize("NFKC").replace(/\b(?:centralstation|station|centralen|c)\b/gu, "").replace(/\s+/gu, " ").trim();
  // Observed official national/regional naming variants, still coordinate-gated.
  if (normalized === "lund klostergården") return "klostergården";
  if (normalized === "ö grevie") return "östra grevie";
  return normalized;
}

function sameStation(stop: StopSnapshot, station: RegionalRailStation): boolean {
  if (stationName(stop.stationName) !== stationName(station[2])) return false;
  if (stop.latitude === null || stop.longitude === null) return false;
  const radians = Math.PI / 180;
  const latitude = (stop.latitude - station[3]) * radians;
  const longitude = (stop.longitude - station[4]) * radians;
  const distance = 6_371_000 * 2 * Math.asin(Math.sqrt(Math.sin(latitude / 2) ** 2
    + Math.cos(stop.latitude * radians) * Math.cos(station[3] * radians) * Math.sin(longitude / 2) ** 2));
  return Number.isFinite(distance) && distance <= 250;
}

function matchesCall(stop: StopSnapshot, call: RegionalRailCall, index: RegionalRailIndex, date: string): boolean {
  const station = index.stations[call[0]];
  if (station === undefined || !sameStation(stop, station)) return false;
  const arrival = serviceSeconds(stop.scheduledArrival, date);
  const departure = serviceSeconds(stop.scheduledDeparture, date);
  if ((stop.scheduledArrival !== null && arrival === null) || (stop.scheduledDeparture !== null && departure === null)) return false;
  // These are two official schedules. Require exact call times rather than
  // letting a nearby service or a platform ordinal identify the train.
  return (arrival !== null || departure !== null)
    && (arrival === null || arrival === call[2])
    && (departure === null || departure === call[3]);
}

export function matchRegionalRailTrip(snapshot: TripSnapshot, index: RegionalRailIndex, now: Date): RegionalRailMatch | null {
  const nowTime = now.getTime();
  const generated = Date.parse(index.generatedAt);
  const expires = Date.parse(index.expiresAt);
  if (![nowTime, generated, expires].every(Number.isFinite) || expires <= generated
    || nowTime < generated - 120_000 || nowTime >= expires) return null;
  if (!/^\d{4}-\d{2}-\d{2}$/u.test(snapshot.serviceDate) || !snapshot.nativeId.includes("se-Trafiklab_")) return null;
  const numbers = [...new Set(snapshot.product.match(/\d+/gu) ?? [])];
  if (numbers.length !== 1) return null;
  const serviceDate = snapshot.serviceDate.replaceAll("-", "");
  const matches: RegionalRailMatch[] = [];
  const timedStops = snapshot.stops.filter((stop) => stop.countryCode.toUpperCase() === "SE"
    && (stop.scheduledArrival !== null || stop.scheduledDeparture !== null));
  if (timedStops.length < 2) return null;
  for (const trip of index.trips) {
    if (trip[1] !== numbers[0] || !index.services[trip[2]]?.includes(serviceDate)) continue;
    const calls = new Map<number, RegionalRailCall>();
    const areas = new Set<string>();
    for (const stop of timedStops) {
      const candidates = trip[3].filter((call) => matchesCall(stop, call, index, snapshot.serviceDate));
      if (candidates.length !== 1) continue;
      calls.set(stop.sequence, candidates[0]!);
      areas.add(index.stations[candidates[0]![0]]![1]);
    }
    // Every available Swedish timed call must agree; two matching anchors are
    // insufficient when another call contradicts the candidate's identity.
    if (areas.size >= 2 && calls.size === timedStops.length) matches.push({ trip, calls });
  }
  return matches.length === 1 ? matches[0]! : null;
}
