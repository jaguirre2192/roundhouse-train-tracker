import { inflateSync } from "fflate";

interface Entry { name: string; size: number; compressed: number; offset: number; method: number; crc: number }
const maxTableBytes = 20 * 1024 * 1024;
const maxCompressedBytes = 4 * 1024 * 1024;

export async function swissBytes(response: Response, maximum: number): Promise<Uint8Array> {
  if (!response.ok || response.body === null) throw new Error("Swiss static request failed");
  const declared = Number(response.headers.get("content-length"));
  if (declared > maximum) { await response.body.cancel(); throw new Error("Oversized Swiss static response"); }
  const reader = response.body.getReader(), chunks: Uint8Array[] = [];
  let length = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.length;
      if (length > maximum) throw new Error("Oversized Swiss static response");
      chunks.push(value);
    }
  } finally { await reader.cancel().catch(() => undefined); reader.releaseLock(); }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return bytes;
}

async function range(url: string, value: string, maximum: number, fetcher: typeof fetch, signal: AbortSignal) {
  const response = await fetcher(url, { headers: { range: value, "accept-encoding": "identity" }, signal, redirect: "follow" });
  const match = response.headers.get("content-range")?.match(/^bytes (\d+)-(\d+)\/(\d+)$/u);
  if (response.status !== 206 || !match) { await response.body?.cancel(); throw new Error("Swiss archive requires byte ranges"); }
  const start = Number(match[1]), end = Number(match[2]), total = Number(match[3]);
  if (![start, end, total].every(Number.isSafeInteger) || start < 0 || end < start || end >= total || total > 1_000_000_000) {
    await response.body?.cancel(); throw new Error("Invalid Swiss archive range");
  }
  const bytes = await swissBytes(response, maximum);
  if (bytes.length !== end - start + 1) throw new Error("Truncated Swiss archive range");
  return { bytes, start, end, total };
}

function entries(bytes: Uint8Array, absoluteStart: number, total: number): Map<string, Entry> {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let end = bytes.length - 22;
  while (end >= 0 && view.getUint32(end, true) !== 0x06054b50) end -= 1;
  if (end < 0 || end + 22 + view.getUint16(end + 20, true) !== bytes.length
    || view.getUint16(end + 4, true) !== 0 || view.getUint16(end + 6, true) !== 0) throw new Error("Invalid Swiss ZIP directory");
  const count = view.getUint16(end + 10, true), size = view.getUint32(end + 12, true), start = view.getUint32(end + 16, true);
  if (count > 32 || count !== view.getUint16(end + 8, true) || size > 60_000 || start + size !== absoluteStart + end) {
    throw new Error("Unsupported Swiss ZIP directory");
  }
  let offset = start - absoluteStart;
  if (offset < 0) throw new Error("Oversized Swiss ZIP directory");
  const result = new Map<string, Entry>();
  for (let i = 0; i < count; i += 1) {
    if (offset + 46 > end || view.getUint32(offset, true) !== 0x02014b50) throw new Error("Invalid Swiss ZIP entry");
    const nameSize = view.getUint16(offset + 28, true), extraSize = view.getUint16(offset + 30, true), commentSize = view.getUint16(offset + 32, true);
    const next = offset + 46 + nameSize + extraSize + commentSize;
    if (next > end) throw new Error("Truncated Swiss ZIP entry");
    const name = new TextDecoder("utf-8", { fatal: true }).decode(bytes.subarray(offset + 46, offset + 46 + nameSize));
    if (result.has(name) || view.getUint16(offset + 8, true) & 1) throw new Error("Duplicate or encrypted Swiss ZIP entry");
    const values = [view.getUint32(offset + 24, true), view.getUint32(offset + 20, true), view.getUint32(offset + 42, true)];
    let extra = offset + 46 + nameSize;
    while (extra < offset + 46 + nameSize + extraSize) {
      if (extra + 4 > next) throw new Error("Invalid Swiss ZIP extra field");
      const tag = view.getUint16(extra, true), length = view.getUint16(extra + 2, true), limit = extra + 4 + length;
      if (limit > offset + 46 + nameSize + extraSize) throw new Error("Invalid Swiss ZIP extra field");
      if (tag === 1) {
        let position = extra + 4;
        for (let index = 0; index < values.length; index += 1) {
          if (values[index] !== 0xffff_ffff) continue;
          if (position + 8 > limit) throw new Error("Truncated Swiss ZIP64 field");
          values[index] = Number(view.getBigUint64(position, true)); position += 8;
        }
      }
      extra = limit;
    }
    const [size, compressed, position] = values as [number, number, number];
    if (!values.every(Number.isSafeInteger) || position + compressed > total) throw new Error("Invalid Swiss ZIP size");
    result.set(name, { name, size, compressed, offset: position, method: view.getUint16(offset + 10, true), crc: view.getUint32(offset + 16, true) });
    offset = next;
  }
  if (offset !== end) throw new Error("Invalid Swiss ZIP directory length");
  return result;
}

function crc32(bytes: Uint8Array): number {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let crc = n;
    for (let k = 0; k < 8; k += 1) crc = crc & 1 ? 0xedb88320 ^ crc >>> 1 : crc >>> 1;
    table[n] = crc;
  }
  let crc = 0xffff_ffff;
  for (const byte of bytes) crc = table[(crc ^ byte) & 255]! ^ crc >>> 8;
  return (crc ^ 0xffff_ffff) >>> 0;
}

/** Read only two small tables; refuse servers that ignore Range instead of downloading the national archive. */
export async function swissStaticTables(url: string, fetcher: typeof fetch, signal: AbortSignal): Promise<Map<string, Uint8Array>> {
  const tail = await range(url, "bytes=-65536", 65_536, fetcher, signal);
  if (tail.end !== tail.total - 1 || tail.start !== Math.max(0, tail.total - 65_536)) throw new Error("Invalid Swiss ZIP suffix range");
  const directory = entries(tail.bytes, tail.start, tail.total), result = new Map<string, Uint8Array>();
  for (const name of ["feed_info.txt", "stops.txt"]) {
    const entry = directory.get(name);
    if (!entry || entry.size > maxTableBytes || entry.compressed > maxCompressedBytes || ![0, 8].includes(entry.method)) {
      throw new Error("Unsupported Swiss static table");
    }
    const end = entry.offset + 30 + new TextEncoder().encode(name).length + 65_535 + entry.compressed - 1;
    const part = await range(url, `bytes=${entry.offset}-${Math.min(end, tail.total - 1)}`, maxCompressedBytes + 65_600, fetcher, signal);
    if (part.start !== entry.offset || part.total !== tail.total || part.end !== Math.min(end, tail.total - 1)) throw new Error("Wrong Swiss table range");
    const view = new DataView(part.bytes.buffer, part.bytes.byteOffset, part.bytes.byteLength);
    if (part.bytes.length < 30 || view.getUint32(0, true) !== 0x04034b50 || view.getUint16(8, true) !== entry.method
      || view.getUint16(6, true) & 1) throw new Error("Invalid Swiss local ZIP entry");
    const nameSize = view.getUint16(26, true), extraSize = view.getUint16(28, true), start = 30 + nameSize + extraSize;
    if (new TextDecoder().decode(part.bytes.subarray(30, 30 + nameSize)) !== name || start + entry.compressed > part.bytes.length) {
      throw new Error("Invalid Swiss local ZIP size");
    }
    const compressed = part.bytes.subarray(start, start + entry.compressed);
    const data = entry.method === 0 ? compressed.slice() : inflateSync(compressed, { out: new Uint8Array(entry.size) });
    if (data.length !== entry.size || crc32(data) !== entry.crc) throw new Error("Corrupt Swiss static table");
    result.set(name, data);
  }
  return result;
}
