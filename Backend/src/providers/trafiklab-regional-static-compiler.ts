import type { RegionalRailCall, RegionalRailIndex, RegionalRailStation, RegionalRailTrip } from "./trafiklab-regional-index.js";
import { parseRegionalRailIndex } from "./trafiklab-regional-index-schema.js";
import { readRegionalStaticArchive, readRegionalTable, type RegionalStaticLimits } from "./trafiklab-regional-static-archive.js";
import { regionalCSV } from "./trafiklab-regional-static-csv.js";

type Row = Readonly<Record<string, string>>;
const dayMs = 86_400_000;
function required(row: Row, key: string): string {
  const value = row[key];
  if (!value || value.length > 160) throw new Error("Invalid regional identifier");
  return value;
}
function date(value: string): number {
  if (!/^\d{8}$/u.test(value)) throw new Error("Invalid regional date");
  const iso = `${value.slice(0, 4)}-${value.slice(4, 6)}-${value.slice(6)}`;
  const epoch = Date.parse(`${iso}T00:00:00Z`);
  if (!Number.isFinite(epoch) || new Date(epoch).toISOString().slice(0, 10) !== iso) throw new Error("Invalid regional date");
  return epoch;
}
function clock(value: string | undefined): number {
  const match = /^(\d{1,2}):([0-5]\d):([0-5]\d)$/u.exec(value ?? "");
  if (!match) throw new Error("Invalid regional call time");
  const seconds = Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]);
  if (seconds > 172_800) throw new Error("Invalid regional call time");
  return seconds;
}

/** Compiles the rail subset without retaining the ZIP or any inflated table. */
export async function compileTrafiklabRegionalStatic(stream: ReadableStream<Uint8Array>, options: RegionalStaticLimits = {}): Promise<RegionalRailIndex> {
  const archive = await readRegionalStaticArchive(stream, options);
  const read = (name: string, columns: string[], cap: number, visit: (row: Row) => void,
    accept?: (line: string, headers: readonly string[]) => boolean) => readRegionalTable(archive, name, regionalCSV(columns, cap, visit, accept));
  let feedVersion = "";
  await read("feed_info.txt", ["feed_version"], 1, (row) => { feedVersion = required(row, "feed_version"); });
  if (!/^\d{4}-\d{2}-\d{2}$/u.test(feedVersion)) throw new Error("Expected dated regional feed version");
  const generated = date(feedVersion.replaceAll("-", ""));
  const firstDate = new Date(generated - dayMs).toISOString().slice(0, 10).replaceAll("-", "");
  const lastDate = new Date(generated + 30 * dayMs).toISOString().slice(0, 10).replaceAll("-", "");
  const routes = new Set<string>();
  await read("routes.txt", ["route_type", "route_id"], 5_000, (row) => { if (row.route_type === "100") routes.add(required(row, "route_id")); });
  const trips = new Map<string, { number: string; service: string; calls: Array<[string, number, number, number]> }>();
  await read("trips.txt", ["route_id", "trip_id", "service_id", "trip_short_name"], 150_000, (row) => {
    if (!routes.has(row.route_id ?? "") || !/^\d+$/u.test(row.trip_short_name ?? "")) return;
    const id = required(row, "trip_id");
    if (trips.has(id) || trips.size >= 10_000) throw new Error("Duplicate or excessive rail trips");
    trips.set(id, { number: row.trip_short_name!, service: required(row, "service_id"), calls: [] });
  });
  const servicesWanted = new Set([...trips.values()].map((trip) => trip.service));
  const dates = new Map<string, Set<string>>();
  // Today's feed uses only exceptions. Honor standard weekly calendars too, so
  // future provider changes cannot silently erase or shift service dates.
  const weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];
  if (archive.tables.has("calendar.txt")) {
    const seen = new Set<string>();
    await read("calendar.txt", ["service_id", "start_date", "end_date", ...weekdays], 10_000, (row) => {
      const id = required(row, "service_id"); if (!servicesWanted.has(id)) return;
      if (seen.has(id)) throw new Error("Duplicate regional calendar"); seen.add(id);
      const start = date(required(row, "start_date")), end = date(required(row, "end_date"));
      if (start > end || weekdays.some((d) => !/^[01]$/u.test(row[d] ?? ""))) throw new Error("Invalid regional calendar");
      const days = new Set<string>();
      for (let epoch = Math.max(start, generated - dayMs); epoch <= end && epoch < generated + 30 * dayMs; epoch += dayMs) {
        const day = new Date(epoch);
        if (row[weekdays[day.getUTCDay()]!] === "1") days.add(day.toISOString().slice(0, 10).replaceAll("-", ""));
      }
      dates.set(id, days);
    });
  }
  const exceptions = new Set<string>();
  await read("calendar_dates.txt", ["service_id", "date", "exception_type"], 200_000, (row) => {
    const id = required(row, "service_id"), day = required(row, "date");
    if (!servicesWanted.has(id) || day < firstDate || day >= lastDate) return;
    date(day);
    if (exceptions.has(`${id}:${day}`) || !/^[12]$/u.test(row.exception_type ?? "")) throw new Error("Invalid regional calendar exception");
    exceptions.add(`${id}:${day}`);
    const days = dates.get(id) ?? new Set<string>();
    if (row.exception_type === "1") days.add(day); else days.delete(day);
    dates.set(id, days);
  });
  for (const [id, trip] of trips) if (!dates.get(trip.service)?.size) trips.delete(id);
  const stops = new Map<string, { parent: string; platform: string; name: string; latitude: number; longitude: number }>();
  await read("stops.txt", ["stop_id", "parent_station", "platform_code", "stop_name", "stop_lat", "stop_lon"], 25_000, (row) => {
    const id = required(row, "stop_id");
    if (stops.has(id)) throw new Error("Duplicate regional stop");
    if (id.length > 24 || (row.parent_station?.length ?? 0) > 24
      || (row.stop_name?.length ?? 0) > 160 || (row.platform_code?.length ?? 0) > 32) throw new Error("Oversized regional stop fields");
    stops.set(id, { parent: row.parent_station ?? "", platform: row.platform_code ?? "", name: row.stop_name ?? "", latitude: Number(row.stop_lat), longitude: Number(row.stop_lon) });
  });
  let callCount = 0;
  await read("stop_times.txt", ["trip_id", "stop_id", "stop_sequence", "arrival_time", "departure_time"], 2_000_000, (row) => {
    const trip = trips.get(row.trip_id ?? ""); if (!trip) return;
    const sequence = Number(required(row, "stop_sequence"));
    if (!Number.isSafeInteger(sequence) || sequence <= 0 || sequence > 1000 || trip.calls.length >= 150 || ++callCount > 150_000) throw new Error("Invalid or excessive rail calls");
    trip.calls.push([required(row, "stop_id"), sequence, clock(row.arrival_time), clock(row.departure_time)]);
  }, (line, headers) => {
    // The official table has trip_id first. Skip irrelevant unquoted rows before
    // allocating fields; reordered/quoted tables use the general CSV path.
    return headers[0] !== "trip_id" || line.startsWith('"') || trips.has(line.slice(0, line.indexOf(",")));
  });
  const parents = new Set<string>();
  for (const trip of trips.values()) for (const [id] of trip.calls) parents.add(stops.get(id)?.parent || id);
  const stations: RegionalRailStation[] = [];
  for (const [id, stop] of [...stops].sort(([a], [b]) => a.localeCompare(b))) {
    if (!parents.has(stop.parent || id)) continue;
    const parent = stops.get(stop.parent) ?? stop;
    if (!parent.name || !Number.isFinite(parent.latitude) || !Number.isFinite(parent.longitude)) continue;
    stations.push([id, stop.parent || id, parent.name, parent.latitude, parent.longitude, stop.platform]);
  }
  const stationIndex = new Map(stations.map((station, i) => [station[0], i]));
  const serviceIndex = new Map<string, number>(), services: string[][] = [], output: RegionalRailTrip[] = [];
  for (const [id, trip] of [...trips].sort(([a], [b]) => a.localeCompare(b))) {
    const calls: RegionalRailCall[] = trip.calls.flatMap(([stop, sequence, arrival, departure]) => {
      const station = stationIndex.get(stop); return station === undefined ? [] : [[station, sequence, arrival, departure] as const];
    }).sort((a, b) => a[1] - b[1]);
    if (new Set(calls.map((call) => stations[call[0]]![1])).size < 2) continue;
    if (!serviceIndex.has(trip.service)) { serviceIndex.set(trip.service, services.length); services.push([...dates.get(trip.service)!].sort()); }
    output.push([id, trip.number, serviceIndex.get(trip.service)!, calls]);
  }
  const index: RegionalRailIndex = { operator: "skane", feedVersion, generatedAt: new Date(generated).toISOString(), expiresAt: new Date(generated + 7 * dayMs).toISOString(), sourceHashes: { regional: archive.hash }, stations, services, trips: output };
  if (!parseRegionalRailIndex(index, new Date(generated))) throw new Error("Invalid compiled regional index");
  return index;
}
