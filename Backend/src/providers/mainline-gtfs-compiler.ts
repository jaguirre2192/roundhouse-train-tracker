import { createHash } from "node:crypto";
import { readRegionalStaticArchive, readRegionalTable } from "./trafiklab-regional-static-archive.js";
import { regionalCSV } from "./trafiklab-regional-static-csv.js";
import { gtfsRailSources, parseGTFSRailIndex, type GTFSRailCountry, type GTFSRailIndex } from "./mainline-gtfs-index.js";

type Row = Readonly<Record<string, string>>;
const dayMs = 86400000;
const weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];
const selectedTables = ["agency.txt", "routes.txt", "trips.txt", "stops.txt", "calendar.txt", "calendar_dates.txt", "stop_times.txt", "translations.txt"];
const requiredTables = ["agency.txt", "routes.txt", "trips.txt", "stops.txt", "stop_times.txt"];
function required(value: string | undefined): string {
  if (!value || value.length > 160) throw new Error("Invalid GTFS identifier");
  return value;
}
function isoDate(value: string): string {
  if (!/^\d{8}$/u.test(value)) throw new Error("Invalid GTFS date");
  const result = `${value.slice(0,4)}-${value.slice(4,6)}-${value.slice(6)}`;
  const time = Date.parse(`${result}T00:00:00Z`);
  if (!Number.isFinite(time) || new Date(time).toISOString().slice(0,10) !== result) throw new Error("Invalid GTFS date");
  return result;
}
function seconds(value: string | undefined): number | null {
  if (!value) return null;
  const match = /^(\d{1,2}):([0-5]\d):([0-5]\d)$/u.exec(value);
  if (!match || Number(match[1]) >= 72) throw new Error("Invalid GTFS time");
  return Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]);
}
interface RawTrip { route: string; service: string; product: string; slot: number; count: number; firstSequence: number; departure: number | null }
interface RawCall { stop: string; sequence: number; arrival: number | null; departure: number | null; pickup: boolean; dropoff: boolean }
function rawCall(row: Row): RawCall {
  const sequence = Number(row.stop_sequence);
  if (!Number.isSafeInteger(sequence) || sequence < 0 || sequence > 1000) throw new Error("Invalid GTFS sequence");
  return { stop: required(row.stop_id), sequence, arrival: seconds(row.arrival_time), departure: seconds(row.departure_time),
    pickup: row.pickup_type !== "1", dropoff: row.drop_off_type !== "1" };
}

/** Bounded compressed tables, two streaming passes; never inflate fares or retain millions of calls. */
export interface MainlineGTFSCompilerOptions {
  country: GTFSRailCountry; now?: Date; sourceURL?: string; signal?: AbortSignal;
  onPhase?: (phase: string, counts: Record<string,number>) => void;
}
export async function* compileMainlineGTFSPhases(stream: ReadableStream<Uint8Array>, options: MainlineGTFSCompilerOptions): AsyncGenerator<{ phase: string },GTFSRailIndex> {
  const now = options.now ?? new Date(), config = gtfsRailSources[options.country];
  const today = new Date(now.getTime() + config.utcOffsetHours * 3600000).toISOString().slice(0,10);
  const start = Date.parse(`${today}T00:00:00Z`) - 2 * dayMs, end = start + 91 * dayMs;
  const validFrom = new Date(start).toISOString().slice(0,10), validUntil = new Date(end).toISOString().slice(0,10);
  const archive = await readRegionalStaticArchive(stream, { selectedTables, requiredTables,
    maxCompressedBytes: 640 * 1024 * 1024, maxSelectedCompressedBytes: 48 * 1024 * 1024,
    maxInflatedBytes: 1100 * 1024 * 1024, ...(options.signal ? { signal: options.signal } : {}) });
  options.onPhase?.("archive-loaded",{});
  yield { phase: "archive-loaded" };
  const read = async (name: string, columns: string[], consume: (row: Row) => void, release = true,
    accept?: (line: string, headers: readonly string[]) => boolean) => {
    if (archive.tables.has(name)) await readRegionalTable(archive, name, regionalCSV(columns, 15000000, consume,accept), release);
  };
  const selectedTripLine = (ids: ReadonlyMap<string,unknown>) => (line: string, headers: readonly string[]) => {
    if (headers[0] !== "trip_id" || line.startsWith('"')) return true;
    const comma = line.indexOf(","); return ids.has(comma < 0 ? line : line.slice(0,comma));
  };
  const agencies = new Set<string>();
  await read("agency.txt", ["agency_id", "agency_timezone"], row => {
    if (!(config.agencies as readonly string[]).includes(row.agency_id ?? "")) return;
    if (row.agency_timezone !== config.timeZone) throw new Error("Unexpected rail agency timezone");
    agencies.add(required(row.agency_id));
  });
  if (agencies.size !== config.agencies.length) throw new Error("Missing allowlisted GTFS agencies");
  const routes = new Map<string, { id: string; agency: string; product: string }>();
  await read("routes.txt", ["route_id", "agency_id", "route_type", "route_short_name", "route_long_name"], row => {
    // Agency membership is primary: route_type=2 would also admit Alishan Forest Railway.
    if (!agencies.has(row.agency_id ?? "")) return;
    if (row.route_type !== "2" && !/^1\d\d$/u.test(row.route_type ?? "")) return;
    const id = required(row.route_id), agency = required(row.agency_id);
    if (routes.has(id)) throw new Error("Duplicate GTFS route");
    const number = /^(?:TRA|THSR)_(\d+)(?:_|$)/u.exec(id)?.[1];
    routes.set(id, { id, agency, product: options.country === "KR" ? row.route_short_name || row.route_long_name || id
      : `${agency} ${number ?? row.route_short_name ?? row.route_long_name ?? id}`.slice(0,200) });
  });
  const trips = new Map<string, RawTrip>();
  await read("trips.txt", ["route_id", "trip_id", "service_id", "trip_short_name"], row => {
    if (!routes.has(row.route_id ?? "")) return;
    const id = required(row.trip_id);
    if (trips.has(id) || trips.size >= 200000) throw new Error("Duplicate or excessive GTFS trips");
    const route = routes.get(row.route_id!)!;
    trips.set(id, { route: route.id, service: required(row.service_id), product: options.country === "KR" ? `${route.product} ${row.trip_short_name || id}` : route.product,
      slot: trips.size, count: 0, firstSequence: Infinity, departure: null });
  });
  // A flat matrix avoids tens of thousands of individual Sets/ArrayBuffers.
  // The 92-day window fits three uint32 words for each service calendar.
  const wanted = new Map<string,number>();
  for (const trip of trips.values()) if (!wanted.has(trip.service)) wanted.set(trip.service,wanted.size);
  const masks = new Uint32Array(wanted.size * 3), hashes = new Uint32Array(trips.size * 8), calendars = new Set<number>();
  const setDay = (slot: number, day: number, present: boolean) => {
    const word = slot * 3 + Math.floor(day / 32), bit = 1 << (day % 32);
    masks[word] = present ? masks[word]! | bit : masks[word]! & ~bit;
  };
  options.onPhase?.("trips-loaded",{ trips: trips.size, services: wanted.size });
  await read("calendar.txt", ["service_id", "start_date", "end_date", ...weekdays], row => {
    if (!wanted.has(row.service_id ?? "")) return;
    const id = required(row.service_id), from = isoDate(required(row.start_date)), to = isoDate(required(row.end_date));
    const slot = wanted.get(id)!;
    if (calendars.has(slot) || from > to || weekdays.some(day => !/^[01]$/u.test(row[day] ?? ""))) throw new Error("Invalid GTFS calendar");
    calendars.add(slot);
    for (let at = Math.max(start, Date.parse(`${from}T00:00:00Z`)); at <= Math.min(end, Date.parse(`${to}T00:00:00Z`)); at += dayMs) {
      const date = new Date(at);
      if (row[weekdays[date.getUTCDay()]!] === "1") setDay(slot,Math.round((at-start)/dayMs),true);
    }
  });
  const exceptions = new Set<number>();
  await read("calendar_dates.txt", ["service_id", "date", "exception_type"], row => {
    if (!wanted.has(row.service_id ?? "")) return;
    const id = required(row.service_id), day = isoDate(required(row.date));
    if (day < validFrom || day > validUntil) return;
    const slot = wanted.get(id)!, dayOffset = Math.round((Date.parse(`${day}T00:00:00Z`)-start)/dayMs), key = slot * 92 + dayOffset;
    if (exceptions.has(key) || !/^[12]$/u.test(row.exception_type ?? "")) throw new Error("Invalid GTFS exception");
    exceptions.add(key);
    setDay(slot,dayOffset,row.exception_type === "1");
  });
  for (const [id, trip] of trips) {
    const slot = wanted.get(trip.service)! * 3;
    if (!(masks[slot] || masks[slot+1] || masks[slot+2])) trips.delete(id);
  }
  options.onPhase?.("calendars-loaded",{ activeTrips: trips.size });
  const columns = ["trip_id", "stop_id", "stop_sequence", "arrival_time", "departure_time", "pickup_type", "drop_off_type"];
  await read("stop_times.txt", columns, row => {
    const trip = trips.get(row.trip_id ?? ""); if (!trip) return;
    const call = rawCall(row), digest = createHash("sha256").update(JSON.stringify(call)).digest();
    // Order-independent digest includes sequence, count and all call fields. Repeated
    // date-specific runs can share one exact pattern even when rows are interleaved.
    for (let i = 0; i < 8; i++) { const slot = trip.slot * 8 + i; hashes[slot] = hashes[slot]! ^ digest.readUInt32BE(i * 4); }
    if (++trip.count > 200) throw new Error("Excessive GTFS calls");
    if (call.sequence < trip.firstSequence) { trip.firstSequence = call.sequence; trip.departure = call.departure; }
  }, false,selectedTripLine(trips));
  options.onPhase?.("calls-fingerprinted",{});
  yield { phase: "calls-fingerprinted" };
  const groups = new Map<string, { representative: string; trip: RawTrip; dates: Uint32Array; calls: RawCall[] }>();
  for (const [id, trip] of trips) {
    if (trip.count < 2 || trip.departure === null) throw new Error("Incomplete selected GTFS trip");
    const signature = JSON.stringify([options.country === "KR" ? id : trip.route, trip.count, ...hashes.subarray(trip.slot*8,trip.slot*8+8)]);
    const offset = wanted.get(trip.service)! * 3;
    const group = groups.get(signature);
    if (group) for (let word = 0; word < 3; word++) group.dates[word] = group.dates[word]! | masks[offset+word]!;
    else groups.set(signature, { representative: id, trip, dates: masks.slice(offset,offset+3), calls: [] });
  }
  const representatives = new Map([...groups.values()].map(group => [group.representative, group]));
  trips.clear(); wanted.clear(); exceptions.clear(); calendars.clear();
  await read("stop_times.txt", columns, row => {
    const group = representatives.get(row.trip_id ?? "");
    if (group) group.calls.push(rawCall(row));
  }, true,selectedTripLine(representatives));
  const wantedStops = new Map<string, string>();
  for (const group of groups.values()) for (const call of group.calls) wantedStops.set(call.stop, routes.get(group.trip.route)!.agency);
  const stations: GTFSRailIndex["stations"] = [];
  await read("stops.txt", ["stop_id", "stop_name", "stop_lat", "stop_lon"], row => {
    const agency = wantedStops.get(row.stop_id ?? ""); if (!agency) return;
    stations.push({ id: required(row.stop_id), name: required(row.stop_name), latitude: Number(row.stop_lat), longitude: Number(row.stop_lon), agency, aliases: [] });
  });
  stations.sort((a,b) => a.id.localeCompare(b.id));
  const stationIndices = new Map(stations.map((s,i) => [s.id,i]));
  await read("translations.txt", ["table_name", "field_name", "language", "record_id", "translation"], row => {
    const station = stations[stationIndices.get(row.record_id ?? "") ?? -1];
    if (station && row.table_name === "stops" && row.field_name === "stop_name" && row.language?.startsWith("en")
      && row.translation && row.translation !== station.name && row.translation.length <= 200 && station.aliases.length < 16) station.aliases.push(row.translation);
  });
  const services: string[][] = [], serviceIndices = new Map<string, number>(), output: GTFSRailIndex["trips"] = [];
  for (const group of groups.values()) {
    const route = routes.get(group.trip.route)!, days: string[] = [];
    for (let day = 0; day < 92; day++) if (group.dates[Math.floor(day/32)]! & (1 << (day%32))) days.push(new Date(start+day*dayMs).toISOString().slice(0,10));
    const signature = days.join(",");
    if (!serviceIndices.has(signature)) { serviceIndices.set(signature, services.length); services.push(days); }
    const calls: GTFSRailIndex["trips"][number]["calls"] = group.calls.sort((a,b) => a.sequence - b.sequence).map(call => {
      const index = stationIndices.get(call.stop);
      if (index === undefined) throw new Error("Missing selected GTFS station");
      return [index, call.sequence, call.arrival, call.departure, call.pickup, call.dropoff];
    });
    output.push({ id: options.country === "KR" ? group.representative : `${group.trip.route}@${group.trip.departure}`, agency: route.agency, product: group.trip.product,
      service: serviceIndices.get(signature)!, calls });
  }
  const publishedDays = services.flat().sort();
  const result = parseGTFSRailIndex({ schemaVersion: 1, country: options.country, sourceURL: options.sourceURL ?? config.url,
    sourceHash: archive.hash, compiledAt: now.toISOString(), validFrom: publishedDays[0] ?? validFrom,
    validUntil: publishedDays.at(-1) ?? validUntil, stations, services, trips: output }, options.country);
  if (!result) throw new Error("Invalid compiled mainline GTFS timetable");
  options.onPhase?.("compiled",{ stations: result.stations.length, trips: result.trips.length });
  return result;
}

export async function compileMainlineGTFS(stream: ReadableStream<Uint8Array>, options: MainlineGTFSCompilerOptions): Promise<GTFSRailIndex> {
  const work = compileMainlineGTFSPhases(stream,options);
  for (;;) { const step = await work.next(); if (step.done) return step.value; }
}
