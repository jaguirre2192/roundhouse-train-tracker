import {
  parseDarwinDocument,
  type DarwinTripFeed,
  type DarwinTripState,
} from "../providers/darwin-realtime.js";
import { FTPControlChannel, type FTPConnectionConfiguration } from "./ftp-control-channel.js";

const persistentChunkBytes = 1024 * 1024;
const listingLifetimeMilliseconds = 60_000;
const snapshotLifetimeMilliseconds = 50 * 60_000;
const messagePattern = /^pPortData\.log\.\d{4}-\d{2}-\d{2}_\d{4}\.gz$/u;

export interface DarwinFTPConfiguration extends FTPConnectionConfiguration {
  messagesDirectory: string;
  snapshotDirectory: string;
}

interface CachedTrip {
  snapshotGeneration: number;
  appliedMessages: Set<string>;
  state: DarwinTripState | null;
}

interface CacheFileRow extends Record<string, SqlStorageValue> { payload: ArrayBuffer }
interface CacheNameRow extends Record<string, SqlStorageValue> { name: string }
interface CacheStateRow extends Record<string, SqlStorageValue> { value: string }
interface CacheStatusRow extends Record<string, SqlStorageValue> {
  compressed_bytes: number;
  message_files: number;
  snapshot_parts: number;
}

export async function gunzipDarwinTripDocument(
  bytes: Uint8Array,
  uid: string,
  serviceDate: string,
): Promise<string> {
  const body = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
  const stream = new Response(body).body;
  if (stream === null) throw new Error("Darwin gzip body was unavailable");
  const reader = stream.pipeThrough(new DecompressionStream("gzip")).getReader();
  const decoder = new TextDecoder();
  const retained: string[] = [];
  let buffer = "";
  let pport = "";

  const drain = (finished: boolean): void => {
    if (pport.length === 0) {
      const opening = buffer.match(/<Pport\b[^>]*>/u)?.[0];
      if (opening !== undefined) pport = opening;
    }
    const tags = [
      { opening: "<schedule", closing: "</schedule>", uid: "uid", date: "ssd" },
      { opening: "<TS", closing: "</TS>", uid: "uid", date: "ssd" },
      { opening: "<trainAlert", closing: "</trainAlert>", uid: "UID", date: "SSD" },
    ] as const;
    while (buffer.length > 0) {
      const next = tags
        .map((tag) => ({ tag, index: buffer.indexOf(tag.opening) }))
        .filter((candidate) => candidate.index >= 0)
        .sort((left, right) => left.index - right.index)[0];
      if (next === undefined) {
        buffer = finished ? "" : buffer.slice(-32);
        return;
      }
      if (next.index > 0) buffer = buffer.slice(next.index);
      const end = buffer.indexOf(next.tag.closing);
      if (end < 0) return;
      const elementEnd = end + next.tag.closing.length;
      const element = buffer.slice(0, elementEnd);
      if (
        element.includes(`${next.tag.uid}="${uid}"`)
        && element.includes(`${next.tag.date}="${serviceDate}"`)
      ) retained.push(element);
      buffer = buffer.slice(elementEnd);
    }
  };

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    drain(false);
  }
  buffer += decoder.decode();
  drain(true);
  return `${pport}${retained.join("")}`;
}

export class DarwinFTPFeed implements DarwinTripFeed {
  private listingExpiresAt = 0;
  private messageNames: string[] = [];
  private readonly messageFiles = new Map<string, Uint8Array>();
  private snapshot: Uint8Array | null = null;
  private snapshotExpiresAt = 0;
  private snapshotGeneration = 0;
  private readonly trips = new Map<string, CachedTrip>();
  private refresh: Promise<void> | null = null;
  private readonly tripRequests = new Map<string, Promise<DarwinTripState | null>>();
  private persistentCacheHydrated = false;

  constructor(
    private readonly configuration: DarwinFTPConfiguration,
    private readonly storage: DurableObjectStorage | null = null,
    private readonly now: () => number = () => Date.now(),
  ) {}

  status(): {
    configured: true;
    ready: boolean;
    compressedBytes: number;
    messageFiles: number;
    snapshotExpiresAt: string | null;
    listingExpiresAt: string | null;
  } {
    if (!this.persistentCacheHydrated && this.storage !== null) {
      const persisted = this.storage.sql.exec<CacheStatusRow>(
        `SELECT
           COALESCE(SUM(LENGTH(payload)), 0) AS compressed_bytes,
           COUNT(DISTINCT CASE WHEN name <> 'snapshot.gz' THEN name END) AS message_files,
           SUM(CASE WHEN name = 'snapshot.gz' THEN 1 ELSE 0 END) AS snapshot_parts
         FROM darwin_cache_files`,
      ).one();
      const snapshotExpiresAt = this.cachedNumber("snapshot_expires_at");
      const listingExpiresAt = this.cachedNumber("listing_expires_at");
      return {
        configured: true,
        ready: (persisted?.snapshot_parts ?? 0) > 0,
        compressedBytes: persisted?.compressed_bytes ?? 0,
        messageFiles: persisted?.message_files ?? 0,
        snapshotExpiresAt: snapshotExpiresAt === 0 ? null : new Date(snapshotExpiresAt).toISOString(),
        listingExpiresAt: listingExpiresAt === 0 ? null : new Date(listingExpiresAt).toISOString(),
      };
    }
    return {
      configured: true,
      ready: this.snapshot !== null,
      compressedBytes: (this.snapshot?.byteLength ?? 0)
        + [...this.messageFiles.values()].reduce((total, value) => total + value.byteLength, 0),
      messageFiles: this.messageFiles.size,
      snapshotExpiresAt: this.snapshotExpiresAt === 0 ? null : new Date(this.snapshotExpiresAt).toISOString(),
      listingExpiresAt: this.listingExpiresAt === 0 ? null : new Date(this.listingExpiresAt).toISOString(),
    };
  }

  async warm(): Promise<boolean> {
    this.hydratePersistentCache();
    await this.ensureFiles();
    return this.snapshot !== null && this.messageNames.length > 0;
  }

  async latestTrip(uid: string, serviceDate: string): Promise<DarwinTripState | null> {
    this.hydratePersistentCache();
    await this.ensureFiles();
    if (this.snapshot === null) return null;
    const key = `${uid}@${serviceDate}`;
    const existing = this.tripRequests.get(key);
    if (existing !== undefined) return existing;
    const request = this.loadTrip(uid, serviceDate).finally(() => this.tripRequests.delete(key));
    this.tripRequests.set(key, request);
    return request;
  }

  private async loadTrip(uid: string, serviceDate: string): Promise<DarwinTripState | null> {
    if (this.snapshot === null) return null;
    const key = `${uid}@${serviceDate}`;
    let cached = this.trips.get(key);
    if (cached === undefined || cached.snapshotGeneration !== this.snapshotGeneration) {
      cached = {
        snapshotGeneration: this.snapshotGeneration,
        appliedMessages: new Set(),
        state: parseDarwinDocument(
          await gunzipDarwinTripDocument(this.snapshot, uid, serviceDate),
          uid,
          serviceDate,
        ),
      };
    }
    for (const name of this.messageNames) {
      if (cached.appliedMessages.has(name)) continue;
      const bytes = this.messageFiles.get(name);
      if (bytes !== undefined) cached.state = parseDarwinDocument(
        await gunzipDarwinTripDocument(bytes, uid, serviceDate),
        uid,
        serviceDate,
        cached.state,
      );
      cached.appliedMessages.add(name);
    }
    if (this.trips.size >= 100 && !this.trips.has(key)) this.trips.clear();
    this.trips.set(key, cached);
    return cached.state;
  }

  private async ensureFiles(): Promise<void> {
    if (this.refresh !== null) return this.refresh;
    const request = this.refreshFiles().finally(() => { this.refresh = null; });
    this.refresh = request;
    return request;
  }

  private async refreshFiles(): Promise<void> {
    const needsSnapshot = this.snapshot === null || this.now() >= this.snapshotExpiresAt;
    const needsListing = this.messageNames.length === 0 || this.now() >= this.listingExpiresAt;
    if (!needsSnapshot && !needsListing) return;

    const changedFiles = new Map<string, Uint8Array>();
    const client = await FTPControlChannel.login(this.configuration);
    try {
      if (needsSnapshot) {
        this.snapshot = await client.retrieve(this.configuration.snapshotDirectory, "snapshot.gz");
        changedFiles.set("snapshot.gz", this.snapshot);
        this.snapshotExpiresAt = this.now() + snapshotLifetimeMilliseconds;
        this.snapshotGeneration += 1;
        this.trips.clear();
        this.messageFiles.clear();
      }

      const names = needsListing
        ? (await client.list(this.configuration.messagesDirectory)).filter((name) => messagePattern.test(name)).sort()
        : this.messageNames;
      for (const name of names) {
        if (!this.messageFiles.has(name)) {
          const bytes = await client.retrieve(this.configuration.messagesDirectory, name);
          this.messageFiles.set(name, bytes);
          changedFiles.set(name, bytes);
        }
      }
      const active = new Set(names);
      for (const name of this.messageFiles.keys()) {
        if (!active.has(name)) this.messageFiles.delete(name);
      }
      this.messageNames = names;
      this.listingExpiresAt = this.now() + listingLifetimeMilliseconds;
      this.persistCache(needsSnapshot, changedFiles, names);
    } finally {
      await client.close();
    }
  }

  private hydratePersistentCache(): void {
    if (this.persistentCacheHydrated || this.storage === null) return;
    this.persistentCacheHydrated = true;
    const sql = this.storage.sql;
    this.snapshot = this.cachedFile("snapshot.gz");
    this.messageNames = sql.exec<CacheNameRow>(
      "SELECT DISTINCT name FROM darwin_cache_files WHERE name <> 'snapshot.gz' ORDER BY name",
    ).toArray().map((row) => row.name).filter((name) => messagePattern.test(name));
    for (const name of this.messageNames) {
      const bytes = this.cachedFile(name);
      if (bytes !== null) this.messageFiles.set(name, bytes);
    }
    this.messageNames = this.messageNames.filter((name) => this.messageFiles.has(name));
    this.snapshotExpiresAt = this.cachedNumber("snapshot_expires_at");
    this.listingExpiresAt = this.cachedNumber("listing_expires_at");
    this.snapshotGeneration = Math.max(1, this.cachedNumber("snapshot_generation"));
  }

  private cachedFile(name: string): Uint8Array | null {
    if (this.storage === null) return null;
    const length = this.storage.sql.exec<{ length: number }>(
      "SELECT COALESCE(SUM(LENGTH(payload)), 0) AS length FROM darwin_cache_files WHERE name = ?",
      name,
    ).one()?.length ?? 0;
    if (length === 0) return null;
    const result = new Uint8Array(length);
    let offset = 0;
    const cursor = this.storage.sql.exec<CacheFileRow>(
      "SELECT payload FROM darwin_cache_files WHERE name = ? ORDER BY part",
      name,
    );
    for (const row of cursor) {
      const chunk = new Uint8Array(row.payload);
      result.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return result;
  }

  private cachedNumber(key: string): number {
    if (this.storage === null) return 0;
    const row = this.storage.sql.exec<CacheStateRow>(
      "SELECT value FROM darwin_cache_state WHERE key = ?",
      key,
    ).toArray()[0];
    const value = Number(row?.value);
    return Number.isFinite(value) ? value : 0;
  }

  private persistCache(
    replaceAll: boolean,
    changedFiles: Map<string, Uint8Array>,
    activeMessages: string[],
  ): void {
    if (this.storage === null || this.snapshot === null) return;
    const now = this.now();
    this.storage.transactionSync(() => {
      const sql = this.storage!.sql;
      if (replaceAll) sql.exec("DELETE FROM darwin_cache_files");
      for (const [name, bytes] of changedFiles) {
        sql.exec("DELETE FROM darwin_cache_files WHERE name = ?", name);
        let part = 0;
        for (let offset = 0; offset < bytes.byteLength; offset += persistentChunkBytes) {
          const chunk = bytes.slice(offset, offset + persistentChunkBytes);
          sql.exec(
            "INSERT INTO darwin_cache_files (name, part, payload, updated_at) VALUES (?, ?, ?, ?)",
            name,
            part,
            chunk.buffer as ArrayBuffer,
            now,
          );
          part += 1;
        }
      }
      const active = new Set(activeMessages);
      const stored = sql.exec<CacheNameRow>(
        "SELECT DISTINCT name FROM darwin_cache_files WHERE name <> 'snapshot.gz'",
      ).toArray();
      for (const row of stored) {
        if (!active.has(row.name)) sql.exec("DELETE FROM darwin_cache_files WHERE name = ?", row.name);
      }
      for (const [key, value] of [
        ["snapshot_expires_at", this.snapshotExpiresAt],
        ["listing_expires_at", this.listingExpiresAt],
        ["snapshot_generation", this.snapshotGeneration],
      ] as const) {
        sql.exec(
          `INSERT INTO darwin_cache_state (key, value, updated_at) VALUES (?, ?, ?)
           ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
          key,
          String(value),
          now,
        );
      }
    });
  }
}
