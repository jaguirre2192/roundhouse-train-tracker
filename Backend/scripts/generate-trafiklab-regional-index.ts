import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { strFromU8, unzipSync } from "fflate";
import type { RegionalRailCall, RegionalRailIndex, RegionalRailStation, RegionalRailTrip } from "../src/providers/trafiklab-regional-index.js";
import { visitCSV } from "./trafiklab-regional-csv.js";

// Offline only. Inputs are the current official CC0 Skåne Regional
// static ZIPs; credentials and large timetables never enter the Worker bundle.
const [regionalPath, outputPath] = process.argv.slice(2);
if (!regionalPath) throw new Error("Pass Skåne Regional ZIP path, optionally output .ts or .json path");
const regionalBytes = await readFile(regionalPath);
const needed = new Set(["routes.txt", "trips.txt", "stops.txt", "stop_times.txt", "calendar_dates.txt", "feed_info.txt"]);
const regional = unzipSync(regionalBytes, { filter: (entry) => needed.has(entry.name) });
function read(archive: Record<string, Uint8Array>, name: string, visit: (record: Readonly<Record<string, string>>) => void): void {
  if (!archive[name]) throw new Error(`Missing ${name}`);
  visitCSV(strFromU8(archive[name]), visit);
  delete archive[name];
}
let feedVersion = "";
read(regional, "feed_info.txt", (row) => { feedVersion = row.feed_version ?? ""; });
if (!/^\d{4}-\d{2}-\d{2}$/u.test(feedVersion)) throw new Error("Expected dated regional feed_version");
const generatedAt = new Date(`${feedVersion}T00:00:00Z`);
const expiresAt = new Date(generatedAt.getTime() + 7 * 86_400_000);
const firstDate = new Date(generatedAt.getTime() - 86_400_000).toISOString().slice(0, 10).replaceAll("-", "");
const lastDate = new Date(generatedAt.getTime() + 30 * 86_400_000).toISOString().slice(0, 10).replaceAll("-", "");
const routes = new Set<string>();
read(regional, "routes.txt", (row) => { if (row.route_type === "100" && row.route_id) routes.add(row.route_id); });
const stops = new Map<string, { parent: string; platform: string; name: string; latitude: number; longitude: number }>();
read(regional, "stops.txt", (row) => {
  if (row.stop_id) stops.set(row.stop_id, { parent: row.parent_station ?? "", platform: row.platform_code ?? "", name: row.stop_name ?? "", latitude: Number(row.stop_lat), longitude: Number(row.stop_lon) });
});
const tripRows = new Map<string, { number: string; service: string; calls: Array<[string, number, number, number]> }>();
read(regional, "trips.txt", (row) => {
  if (routes.has(row.route_id ?? "") && row.trip_id && row.service_id && /^\d+$/u.test(row.trip_short_name ?? "")) {
    if (tripRows.has(row.trip_id)) throw new Error("Duplicate static trip identity");
    tripRows.set(row.trip_id, { number: row.trip_short_name!, service: row.service_id, calls: [] });
  }
});
const dates = new Map<string, Set<string>>();
read(regional, "calendar_dates.txt", (row) => {
  if (!row.service_id || !row.date || row.date < firstDate || row.date >= lastDate) return;
  const values = dates.get(row.service_id) ?? new Set<string>();
  if (row.exception_type === "1") values.add(row.date);
  else if (row.exception_type === "2") values.delete(row.date);
  dates.set(row.service_id, values);
});
for (const [id, trip] of tripRows) if (!dates.get(trip.service)?.size) tripRows.delete(id);
function seconds(value: string | undefined): number {
  if (!value || !/^\d{1,3}:\d{2}:\d{2}$/u.test(value)) return -1;
  const [hours, minutes, seconds] = value.split(":").map(Number);
  return hours! * 3_600 + minutes! * 60 + seconds!;
}
read(regional, "stop_times.txt", (row) => {
  const trip = tripRows.get(row.trip_id ?? "");
  if (!trip || !row.stop_id) return;
  const sequence = Number(row.stop_sequence);
  const arrival = seconds(row.arrival_time), departure = seconds(row.departure_time);
  if (!Number.isInteger(sequence) || sequence <= 0 || arrival < 0 || departure < 0) throw new Error("Invalid rail call");
  trip.calls.push([row.stop_id, sequence, arrival, departure]);
});
const railParents = new Set<string>();
for (const trip of tripRows.values()) for (const [id] of trip.calls) railParents.add(stops.get(id)?.parent || id);
const stations: RegionalRailStation[] = [];
for (const [id, stop] of [...stops.entries()].sort(([left], [right]) => left.localeCompare(right))) {
  if (!railParents.has(stop.parent || id)) continue;
  const parent = stops.get(stop.parent) ?? stop;
  if (!parent.name || !Number.isFinite(parent.latitude) || !Number.isFinite(parent.longitude)) continue;
  stations.push([id, stop.parent || id, parent.name, parent.latitude, parent.longitude, stop.platform]);
}
const stationIndex = new Map(stations.map((station, index) => [station[0], index]));
const services: string[][] = [];
const serviceIndex = new Map<string, number>();
const trips: RegionalRailTrip[] = [];
for (const [id, trip] of [...tripRows.entries()].sort(([left], [right]) => left.localeCompare(right))) {
  const calls: RegionalRailCall[] = trip.calls.flatMap(([stop, sequence, arrival, departure]) => {
    const station = stationIndex.get(stop);
    return station === undefined ? [] : [[station, sequence, arrival, departure] as const];
  }).sort((left, right) => left[1] - right[1]);
  if (new Set(calls.map((call) => stations[call[0]]![1])).size < 2) continue;
  if (!serviceIndex.has(trip.service)) {
    serviceIndex.set(trip.service, services.length); services.push([...dates.get(trip.service)!].sort());
  }
  trips.push([id, trip.number, serviceIndex.get(trip.service)!, calls]);
}
if (trips.length === 0) throw new Error("No mapped eligible rail journeys");
const index: RegionalRailIndex = {
  operator: "skane", feedVersion, generatedAt: generatedAt.toISOString(), expiresAt: expiresAt.toISOString(),
  sourceHashes: {
    regional: createHash("sha256").update(regionalBytes).digest("hex"),
  }, stations, services, trips,
};
const json = JSON.stringify(index);
const output = outputPath ?? new URL("../src/providers/trafiklab-skane-index.generated.ts", import.meta.url);
await writeFile(output, outputPath?.endsWith(".json") ? `${json}\n`
  : '// Generated offline from official Trafiklab CC0 static feeds. Rebuild daily; fails closed after expiresAt.\n'
    + 'import type { RegionalRailIndex } from "./trafiklab-regional-index.js";\n'
    + `export const trafiklabSkaneRailIndex = JSON.parse(${JSON.stringify(json)}) as RegionalRailIndex;\n`);
console.log(JSON.stringify({ trips: trips.length, stations: stations.length, services: services.length, bytes: json.length, feedVersion, expiresAt: index.expiresAt }));
