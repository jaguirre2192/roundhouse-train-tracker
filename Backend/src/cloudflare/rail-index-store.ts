import { createHash } from "node:crypto";
import { maximumRegionalIndexBytes, parseRegionalRailIndex } from "../providers/trafiklab-regional-index-schema.js";

const manifestKey = "rail-index:skane:manifest";
const chunkKey = (index: number) => `rail-index:skane:chunk:${index}`;
const chunkCharacters = 32 * 1_024; // Even non-ASCII UTF-8 stays below the 128KiB value limit.
interface Manifest { count: number; version: string; hash: string; storedAt: string }

export class RailIndexStore {
  constructor(private readonly storage: DurableObjectStorage, private readonly now: () => Date = () => new Date()) {}

  async load(): Promise<unknown> {
    return this.storage.transaction(async (transaction) => {
      const manifest = await transaction.get<Manifest>(manifestKey);
      if (manifest === undefined || !Number.isInteger(manifest.count) || manifest.count < 1 || manifest.count > 64) return null;
      const keys = Array.from({ length: manifest.count }, (_, index) => chunkKey(index));
      const chunks = await transaction.get<string>(keys);
      if (chunks.size !== keys.length || keys.some((key) => typeof chunks.get(key) !== "string")) return null;
      const text = keys.map((key) => chunks.get(key)!).join("");
      if (new TextEncoder().encode(text).length > maximumRegionalIndexBytes
        || createHash("sha256").update(text).digest("hex") !== manifest.hash) return null;
      try { return JSON.parse(text) as unknown; } catch { return null; }
    });
  }

  async save(value: unknown): Promise<{ outcome: "stored" | "unchanged" | "older" | "invalid"; feedVersion?: string }> {
    const now = this.now(), index = parseRegionalRailIndex(value, now);
    if (index === null) return { outcome: "invalid" };
    const text = JSON.stringify(index);
    if (new TextEncoder().encode(text).length > maximumRegionalIndexBytes) return { outcome: "invalid" };
    const hash = createHash("sha256").update(text).digest("hex");
    return this.storage.transaction(async (transaction) => {
      const previous = await transaction.get<Manifest>(manifestKey);
      if (previous !== undefined && previous.version > index.feedVersion) return { outcome: "older", feedVersion: previous.version };
      if (previous?.hash === hash) return { outcome: "unchanged", feedVersion: index.feedVersion };
      const count = Math.ceil(text.length / chunkCharacters);
      if (count > 64) return { outcome: "invalid" };
      const entries: Record<string, unknown> = {};
      for (let i = 0; i < count; i += 1) entries[chunkKey(i)] = text.slice(i * chunkCharacters, (i + 1) * chunkCharacters);
      entries[manifestKey] = { count, version: index.feedVersion, hash, storedAt: now.toISOString() } satisfies Manifest;
      await transaction.put(entries);
      const previousCount = previous !== undefined && Number.isInteger(previous.count) && previous.count <= 64 ? previous.count : 0;
      const obsolete = Array.from({ length: Math.max(0, previousCount - count) }, (_, i) => chunkKey(count + i));
      if (obsolete.length > 0) await transaction.delete(obsolete);
      return { outcome: "stored", feedVersion: index.feedVersion };
    });
  }
}
