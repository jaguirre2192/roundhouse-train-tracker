import { Unzip, UnzipInflate } from "fflate";

export const renfeStaticUrl = "https://ssl.renfe.com/gtransit/Fichero_AV_LD/google_transit.zip";

export interface RenfeStaticCall {
  stationId: string;
  sequence: number;
  arrival: number | null;
  departure: number | null;
}

export interface RenfeStaticIndex {
  trips: Map<string, { routeId: string; serviceId: string }>;
  calls: Map<string, RenfeStaticCall[]>;
  calendars: Map<string, { start: string; end: string; weekdays: number }>;
  exceptions: Map<string, Map<string, boolean>>;
}

export interface RenfeStaticLoadOptions {
  url?: string;
  maxCompressedBytes?: number;
  maxUncompressedBytes?: number;
  timeoutMs?: number;
}

const selectedFiles = new Set(["agency.txt", "trips.txt", "stop_times.txt", "calendar.txt", "calendar_dates.txt"]);
const chunkSize = 16 * 1024;
const weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];

function required(row: Record<string, string>, name: string): string {
  const value = row[name];
  if (value === undefined || value.length === 0 || value.length > 256) throw new Error(`Invalid Renfe ${name}`);
  return value;
}

function date(value: string): string {
  if (!/^\d{8}$/u.test(value)) throw new Error("Invalid Renfe calendar date");
  const iso = `${value.slice(0, 4)}-${value.slice(4, 6)}-${value.slice(6, 8)}`;
  const parsed = new Date(`${iso}T12:00:00Z`);
  if (!Number.isFinite(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== iso) throw new Error("Invalid Renfe calendar date");
  return value;
}

function clock(value: string | undefined): number | null {
  if (value === "" || value === undefined) return null;
  const match = /^(\d{1,2}):([0-5]\d):([0-5]\d)$/u.exec(value);
  if (match === null || Number(match[1]) > 71) throw new Error("Invalid Renfe stop time");
  return Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]);
}

/** Selected GTFS tables have one CSV record per line. Quoted newlines fail closed. */
function cells(line: string): string[] {
  const values: string[] = [];
  let value = "", quoted = false, closed = false;
  for (let i = 0; i < line.length; i += 1) {
    const char = line[i]!;
    if (quoted) {
      if (char === '"' && line[i + 1] === '"') { value += '"'; i += 1; }
      else if (char === '"') { quoted = false; closed = true; }
      else value += char;
    } else if (char === ",") { values.push(value.trim()); value = ""; closed = false; }
    else if (char === '"' && value.trim() === "" && !closed) { quoted = true; value = ""; }
    else if (char === '"' || (closed && char.trim() !== "")) throw new Error("Invalid Renfe CSV quoting");
    else value += char;
  }
  if (quoted) throw new Error("Unsupported multiline Renfe CSV record");
  values.push(value.trim());
  return values;
}

function csvConsumer(consume: (row: Record<string, string>) => void): (data: Uint8Array, final: boolean) => void {
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let pending = "", headers: string[] | null = null, records = 0;
  const line = (value: string) => {
    if (value.trim() === "") return;
    // Renfe pads every record to a fixed width. Remove padding outside the final
    // quoted field before the character loop creates transient string fragments.
    const fields = cells(value.trimEnd());
    if (headers === null) {
      headers = fields;
      if (new Set(headers).size !== headers.length) throw new Error("Duplicate Renfe CSV header");
      return;
    }
    if (fields.length !== headers.length || ++records > 200_000) throw new Error("Invalid Renfe CSV record count");
    consume(Object.fromEntries(headers.map((header, index) => [header, fields[index]!])));
  };
  const text = (value: string) => {
    pending += value;
    let newline: number;
    while ((newline = pending.indexOf("\n")) !== -1) {
      if (newline > 16_384) throw new Error("Oversized Renfe CSV line");
      line(pending.slice(0, newline));
      pending = pending.slice(newline + 1);
    }
    if (pending.length > 16_384) throw new Error("Oversized Renfe CSV line");
  };
  return (data, final) => {
    for (let offset = 0; offset < data.length; offset += chunkSize) text(decoder.decode(data.subarray(offset, offset + chunkSize), { stream: true }));
    if (final) { text(decoder.decode()); line(pending); pending = ""; if (headers === null) throw new Error("Empty Renfe CSV"); }
  };
}

function rowConsumer(index: RenfeStaticIndex, file: string, agency: { count: number }): (row: Record<string, string>) => void {
  return (row) => {
    if (file === "agency.txt") {
      if (required(row, "agency_timezone") !== "Europe/Madrid") throw new Error("Unsupported Renfe timezone");
      agency.count += 1;
    } else if (file === "trips.txt") {
      const id = required(row, "trip_id");
      if (index.trips.has(id) || index.trips.size >= 30_000) throw new Error("Duplicate or excessive Renfe trips");
      index.trips.set(id, { routeId: required(row, "route_id"), serviceId: required(row, "service_id") });
    } else if (file === "stop_times.txt") {
      const id = required(row, "trip_id"), sequence = Number(required(row, "stop_sequence"));
      if (!Number.isSafeInteger(sequence) || sequence < 0) throw new Error("Invalid Renfe stop sequence");
      const calls = index.calls.get(id) ?? [];
      if (calls.length >= 500 || index.calls.size > 30_000) throw new Error("Excessive Renfe calls");
      calls.push({ stationId: required(row, "stop_id"), sequence, arrival: clock(row.arrival_time), departure: clock(row.departure_time) });
      index.calls.set(id, calls);
    } else if (file === "calendar.txt") {
      const id = required(row, "service_id");
      if (index.calendars.has(id)) throw new Error("Duplicate Renfe calendar");
      let mask = 0;
      weekdays.forEach((day, bit) => {
        const flag = required(row, day);
        if (flag !== "0" && flag !== "1") throw new Error("Invalid Renfe weekday");
        if (flag === "1") mask |= 1 << bit;
      });
      const start = date(required(row, "start_date")), end = date(required(row, "end_date"));
      if (start > end) throw new Error("Reversed Renfe calendar");
      index.calendars.set(id, { start, end, weekdays: mask });
    } else {
      const id = required(row, "service_id"), day = date(required(row, "date")), type = required(row, "exception_type");
      if (type !== "1" && type !== "2") throw new Error("Invalid Renfe calendar exception");
      const exceptions = index.exceptions.get(id) ?? new Map<string, boolean>();
      if (exceptions.has(day)) throw new Error("Duplicate Renfe calendar exception");
      exceptions.set(day, type === "1"); index.exceptions.set(id, exceptions);
    }
  };
}

/** Incremental ZIP and CSV processing; retains only compact identity/calendar fields. */
export async function loadRenfeStaticIndex(fetcher: typeof fetch, options: RenfeStaticLoadOptions = {}): Promise<RenfeStaticIndex> {
  const maxCompressed = options.maxCompressedBytes ?? 1024 * 1024;
  const maxUncompressed = options.maxUncompressedBytes ?? 48 * 1024 * 1024;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), options.timeoutMs ?? 15_000);
  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
  const activeFiles: Array<{ terminate: () => void }> = [];
  try {
    const response = await fetcher(options.url ?? renfeStaticUrl, { signal: controller.signal });
    if (!response.ok || response.body === null) throw new Error("Renfe timetable unavailable");
    const length = Number(response.headers.get("content-length"));
    if (Number.isFinite(length) && length > maxCompressed) throw new Error("Oversized Renfe ZIP");
    const index: RenfeStaticIndex = { trips: new Map(), calls: new Map(), calendars: new Map(), exceptions: new Map() };
    const agency = { count: 0 }, found = new Set<string>(), completed = new Set<string>();
    let compressed = 0, inflated = 0, declared = 0, entries = 0;
    const unzip = new Unzip((file) => {
      if (++entries > 32) throw new Error("Excessive Renfe ZIP entries");
      if (file.originalSize !== undefined) declared += file.originalSize;
      if (declared > maxUncompressed) throw new Error("Oversized Renfe inflated ZIP");
      if (!selectedFiles.has(file.name)) return;
      if (found.has(file.name)) throw new Error("Duplicate Renfe ZIP file");
      found.add(file.name); activeFiles.push(file);
      const consume = csvConsumer(rowConsumer(index, file.name, agency));
      let fileBytes = 0;
      file.ondata = (error, data, final) => {
        if (error !== null) throw error;
        inflated += data.length; fileBytes += data.length;
        if (inflated > maxUncompressed) throw new Error("Oversized Renfe CSV data");
        consume(data, final);
        if (final) {
          if (file.originalSize !== undefined && fileBytes !== file.originalSize) throw new Error("Truncated Renfe ZIP entry");
          completed.add(file.name);
        }
      };
      file.start();
    });
    unzip.register(UnzipInflate);
    reader = response.body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      compressed += value.length;
      if (compressed > maxCompressed) throw new Error("Oversized Renfe ZIP");
      for (let offset = 0; offset < value.length; offset += chunkSize) unzip.push(value.subarray(offset, offset + chunkSize), false);
    }
    unzip.push(new Uint8Array(), true);
    if (completed.size !== selectedFiles.size || agency.count === 0 || index.trips.size === 0) throw new Error("Incomplete Renfe timetable");
    for (const [id, calls] of index.calls) {
      if (!index.trips.has(id)) throw new Error("Unknown Renfe stop-time trip");
      calls.sort((a, b) => a.sequence - b.sequence);
      if (calls.some((call, i) => i > 0 && call.sequence === calls[i - 1]!.sequence)) throw new Error("Duplicate Renfe stop sequence");
    }
    return index;
  } finally {
    clearTimeout(timer); controller.abort();
    if (reader !== undefined) { await reader.cancel().catch(() => undefined); reader.releaseLock(); }
    activeFiles.forEach((file) => file.terminate());
  }
}
