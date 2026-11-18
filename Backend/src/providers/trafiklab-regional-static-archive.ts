import { createHash } from "node:crypto";
import { Inflate, Unzip, type AsyncFlateStreamHandler, type UnzipFile } from "fflate";

export interface RegionalStaticLimits {
  signal?: AbortSignal;
  maxCompressedBytes?: number;
  maxSelectedCompressedBytes?: number;
  maxInflatedBytes?: number;
  selectedTables?: readonly string[];
  requiredTables?: readonly string[];
}
interface CompressedTable { compression: number; chunks: Uint8Array[]; originalSize?: number }
export interface RegionalStaticArchive {
  tables: Map<string, CompressedTable>;
  hash: string;
  signal: AbortSignal | undefined;
  remainingInflatedBytes: number;
}

const selected = new Set(["feed_info.txt", "routes.txt", "trips.txt", "stops.txt", "calendar.txt", "calendar_dates.txt", "stop_times.txt"]);
const chunkSize = 16 * 1024;

// Unzip normally retains unopened files. Starting every entry with this decoder
// lets us discard shapes immediately and retain only bounded *compressed* tables.
class RawDeflate {
  static compression = 8;
  ondata!: AsyncFlateStreamHandler;
  push(data: Uint8Array<ArrayBuffer>, final: boolean): void { this.ondata(null, data, final); }
}

/** One download; routes may follow stop_times, so defer selected decompression. */
export async function readRegionalStaticArchive(stream: ReadableStream<Uint8Array>, limits: RegionalStaticLimits): Promise<RegionalStaticArchive> {
  const selectedNames = limits.selectedTables ? new Set(limits.selectedTables) : selected;
  const maximum = limits.maxCompressedBytes ?? 64 * 1024 * 1024;
  const selectedMaximum = limits.maxSelectedCompressedBytes ?? 20 * 1024 * 1024;
  const inflatedMaximum = limits.maxInflatedBytes ?? 192 * 1024 * 1024;
  const tables = new Map<string, CompressedTable>(), completed = new Set<string>(), names = new Set<string>();
  const files: UnzipFile[] = [], hash = createHash("sha256");
  let compressed = 0, retained = 0, declaredSelected = 0;
  const unzip = new Unzip((file) => {
    if (names.has(file.name) || names.size >= 32) throw new Error("Duplicate or excessive regional ZIP entries");
    names.add(file.name); files.push(file);
    if (file.compression !== 0 && file.compression !== 8) throw new Error("Unsupported regional ZIP compression");
    const table: CompressedTable | undefined = selectedNames.has(file.name)
      ? { compression: file.compression, chunks: [], ...(file.originalSize === undefined ? {} : { originalSize: file.originalSize }) } : undefined;
    if (table) {
      tables.set(file.name, table);
      declaredSelected += file.originalSize ?? 0;
      if (declaredSelected > inflatedMaximum) throw new Error("Oversized regional inflated tables");
    }
    let tail: Uint8Array | null = null, tailSize = 0;
    file.ondata = (error, data, final) => {
      if (error) throw error;
      if (table && data.length) {
        retained += data.length;
        if (retained > selectedMaximum) throw new Error("Oversized regional compressed tables");
        // Coalesce tiny network chunks and detach large backing buffers. Retained
        // array-object count stays bounded even for one-byte input fragments.
        for (let offset = 0; offset < data.length;) {
          tail ??= new Uint8Array(chunkSize);
          const count = Math.min(chunkSize - tailSize, data.length - offset);
          tail.set(data.subarray(offset, offset + count), tailSize);
          tailSize += count; offset += count;
          if (tailSize === chunkSize) { table.chunks.push(tail); tail = null; tailSize = 0; }
        }
      }
      if (final) {
        if (table && tail) { table.chunks.push(tail.slice(0, tailSize)); tail = null; }
        completed.add(file.name);
      }
    };
    file.start();
  });
  unzip.register(RawDeflate);
  const reader = stream.getReader();
  const abort = () => { void reader.cancel().catch(() => undefined); };
  limits.signal?.addEventListener("abort", abort, { once: true });
  try {
    for (;;) {
      limits.signal?.throwIfAborted();
      const { done, value } = await reader.read();
      limits.signal?.throwIfAborted();
      if (done) break;
      compressed += value.length;
      if (compressed > maximum) throw new Error("Oversized regional ZIP");
      hash.update(value);
      for (let offset = 0; offset < value.length; offset += chunkSize) unzip.push(value.subarray(offset, offset + chunkSize), false);
    }
    unzip.push(new Uint8Array(), true);
    for (const name of limits.requiredTables ?? [...selected].filter(name => name !== "calendar.txt")) {
      if (!tables.has(name) || !completed.has(name)) throw new Error("Incomplete regional timetable");
    }
    return { tables, hash: hash.digest("hex"), signal: limits.signal, remainingInflatedBytes: inflatedMaximum };
  } finally {
    limits.signal?.removeEventListener("abort", abort);
    await reader.cancel().catch(() => undefined); reader.releaseLock();
    files.forEach((file) => file.terminate());
  }
}

/** Inflates one selected entry in bounded compressed chunks, then releases it. */
export async function readRegionalTable(archive: RegionalStaticArchive, name: string, consume: (data: Uint8Array, final: boolean) => void, release = true): Promise<void> {
  const table = archive.tables.get(name);
  if (!table) throw new Error("Missing regional table");
  let size = 0;
  const ondata = (data: Uint8Array, final: boolean) => {
    archive.signal?.throwIfAborted();
    size += data.length; archive.remainingInflatedBytes -= data.length;
    if (archive.remainingInflatedBytes < 0) throw new Error("Oversized regional inflated tables");
    consume(data, final);
  };
  const inflate = table.compression === 8 ? new Inflate(ondata) : null;
  try {
    let batches = 0;
    for (const chunk of table.chunks) {
      archive.signal?.throwIfAborted();
      if (inflate) inflate.push(chunk, false); else ondata(chunk, false);
      // Let the outer timeout/cancellation run during the large stop_times table.
      if (++batches % 32 === 0) await new Promise<void>((resolve) => setTimeout(resolve, 0));
    }
    if (inflate) inflate.push(new Uint8Array(), true); else ondata(new Uint8Array(), true);
    if (table.originalSize !== undefined && size !== table.originalSize) throw new Error("Truncated regional table");
  } finally { if (release) { table.chunks.length = 0; archive.tables.delete(name); } }
}
