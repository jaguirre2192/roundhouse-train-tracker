import { createHash } from "node:crypto";
import { maximumGTFSRailIndexBytes, parseGTFSRailIndex, type GTFSRailCountry } from "../providers/mainline-gtfs-index.js";

const chunkCharacters = 32 * 1024, maxChunks = 256;
interface Manifest { count: number; hash: string; contentHash: string; compiledAt: string }
export type GTFSIndexPublication = { outcome: "stored" | "unchanged" | "older" | "invalid"; country?: GTFSRailCountry; compiledAt?: string; sourceHash?: string };

export class GTFSRailIndexStore {
  constructor(private readonly storage: DurableObjectStorage, private readonly country: GTFSRailCountry) {}
  private key(suffix: string) { return `mainline-gtfs:${this.country}:${suffix}`; }
  async load(): Promise<unknown> {
    return this.storage.transaction(async transaction => {
      const manifest = await transaction.get<Manifest>(this.key("manifest"));
      if (!manifest || !Number.isInteger(manifest.count) || manifest.count < 1 || manifest.count > maxChunks) return null;
      const pieces: string[] = [];
      for (let start = 0; start < manifest.count; start += 100) {
        const keys = Array.from({ length: Math.min(100,manifest.count-start) },(_,i) => this.key(`chunk:${start+i}`));
        const values = await transaction.get<string>(keys);
        if (keys.some(key => typeof values.get(key) !== "string")) return null;
        pieces.push(...keys.map(key => values.get(key)!));
      }
      const text = pieces.join("");
      if (new TextEncoder().encode(text).length > maximumGTFSRailIndexBytes || createHash("sha256").update(text).digest("hex") !== manifest.hash) return null;
      try { return JSON.parse(text) as unknown; } catch { return null; }
    });
  }
  async health() {
    const index = parseGTFSRailIndex(await this.load(),this.country);
    return { country: this.country, ready: index !== null, compiledAt: index?.compiledAt ?? null, sourceHash: index?.sourceHash ?? null,
      stations: index?.stations.length ?? 0, trips: index?.trips.length ?? 0, validFrom: index?.validFrom ?? null, validUntil: index?.validUntil ?? null };
  }
  async save(value: unknown): Promise<GTFSIndexPublication> {
    const index = parseGTFSRailIndex(value,this.country);
    if (!index) return { outcome: "invalid" };
    const text = JSON.stringify(index), bytes = new TextEncoder().encode(text).length;
    if (bytes > maximumGTFSRailIndexBytes) return { outcome: "invalid" };
    const hash = createHash("sha256").update(text).digest("hex");
    const contentHash = createHash("sha256").update(JSON.stringify({ ...index, compiledAt: "" })).digest("hex");
    return this.storage.transaction(async transaction => {
      const previous = await transaction.get<Manifest>(this.key("manifest"));
      const receipt = { country: this.country, compiledAt: index.compiledAt, sourceHash: index.sourceHash };
      if (previous && Date.parse(previous.compiledAt) > Date.parse(index.compiledAt)) return { outcome: "older", ...receipt };
      if (previous?.contentHash === contentHash) return { outcome: "unchanged", ...receipt };
      const count = Math.ceil(text.length / chunkCharacters);
      if (count > maxChunks) return { outcome: "invalid" };
      for (let start = 0; start < count; start += 100) {
        const pieces: Record<string,string> = {};
        for (let i = start; i < Math.min(count,start+100); i++) pieces[this.key(`chunk:${i}`)] = text.slice(i*chunkCharacters,(i+1)*chunkCharacters);
        await transaction.put(pieces);
      }
      await transaction.put(this.key("manifest"),{ count, hash, contentHash, compiledAt: index.compiledAt } satisfies Manifest);
      if (previous && previous.count <= maxChunks) for (let start = count; start < previous.count; start += 100) {
        await transaction.delete(Array.from({ length: Math.min(100,previous.count-start) },(_,i) => this.key(`chunk:${start+i}`)));
      }
      return { outcome: "stored", ...receipt };
    });
  }
}
