import { createHash } from "node:crypto";
import type { TripSnapshot } from "../domain/snapshot.js";
import { denmarkSiriJourneyKey, mergeDenmarkSiriEvents } from "../providers/denmark-siri-events.js";
import { denmarkSiriTrainNumber } from "../providers/denmark-siri-matching.js";
import { denmarkSiriMaximumAgeMilliseconds, isDenmarkSiriOperatorRef, type DenmarkSiriJourney, type DenmarkSiriOperatorRef } from "../providers/denmark-siri-models.js";
import { parseDenmarkSiriDelivery } from "../providers/denmark-siri-parser.js";
import { validDenmarkSiriBatch } from "./denmark-siri-batch.js";

interface SiriTransaction {
  get<T>(key: string): Promise<T | undefined>;
  put(key: string, value: unknown): Promise<void>;
  delete(keys: string[]): Promise<number>;
}
export interface DenmarkSiriStorage {
  transaction<T>(work: (transaction: SiriTransaction) => Promise<T>): Promise<T>;
}

export const denmarkSiriStoreLimits = {
  journeys: 512, bytes: 4 * 1024 * 1024, journeyBytes: 1024 * 1024,
  chunkCharacters: 24 * 1024, manifestBytes: 120 * 1024,
} as const;
const futureTolerance = 120_000;
const maximumChunks = 64;
// Keys include date/train and a hash of the full dated journey identity. Several
// runs with the same public train number remain distinct for the strict matcher.
type Entry = [key: string, observedAt: string, chunks: number, bytes: number, hash: string, calls: number];
interface Manifest { version: 1; entries: Entry[] }
type Selection = "all" | { serviceDate: string; trainNumber: string } | null;
interface StateResult { changed: boolean; journeys: DenmarkSiriJourney[]; entries: Entry[] }
export interface DenmarkSiriIngestResult {
  outcome: "stored" | "unchanged" | "ignored-stale";
  journeys: number;
  /** Retained calls, including older partial calls until the next relevant read. */
  calls: number;
}
export interface DenmarkSiriBatchIngestResult extends DenmarkSiriIngestResult {
  deliveries: number;
  ignoredStale: number;
}
interface OperatorHealth {
  journeys: number;
  calls: number;
  latestObservedAt: string | null;
  samples: Array<Pick<DenmarkSiriJourney, "trainNumber" | "serviceDate" | "operatorRef" | "observedAt"> & {
    callCount: number;
    anchors: Array<Pick<DenmarkSiriJourney["calls"][number], "stopPointRef" | "aimedArrival" | "aimedDeparture">>;
  }>;
}
export interface DenmarkSiriHealth {
  source: "denmark-siri";
  ready: boolean;
  journeys: number;
  calls: number;
  bytes: number;
  latestObservedAt: string | null;
  oldestObservedAt: string | null;
  latestReceivedAt: string | null;
  /** Additive diagnostics for public provider services, never saved user trips. */
  operators?: Record<DenmarkSiriOperatorRef, OperatorHealth>;
}

export class DenmarkSiriIngestError extends Error {
  constructor(message = "Invalid Denmark SIRI delivery") {
    super(message); this.name = "DenmarkSiriIngestError";
  }
}

function hash(value: string): string { return createHash("sha256").update(value).digest("hex"); }
function bytes(value: string): number { return new TextEncoder().encode(value).byteLength; }
function instant(value: unknown): value is string {
  return typeof value === "string"
    && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)$/u.test(value)
    && Number.isFinite(Date.parse(value));
}
function date(value: unknown): value is string {
  return typeof value === "string" && /^\d{4}-\d\d-\d\d$/u.test(value)
    && Number.isFinite(Date.parse(value)) && new Date(value).toISOString().slice(0, 10) === value;
}
function nowDate(value?: string): Date {
  if (value !== undefined && !instant(value)) throw new DenmarkSiriIngestError("Invalid receipt clock");
  return value === undefined ? new Date() : new Date(value);
}
function fresh(value: string, now: number): boolean {
  const observed = Date.parse(value);
  return observed <= now + futureTolerance && now - observed <= denmarkSiriMaximumAgeMilliseconds;
}

function validJourney(value: unknown): value is DenmarkSiriJourney {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
  const journey = value as Partial<DenmarkSiriJourney>;
  if (journey.producerRef !== "RKRP_RTH" || !isDenmarkSiriOperatorRef(journey.operatorRef) || !date(journey.serviceDate)
    || typeof journey.journeyRef !== "string" || journey.journeyRef.length < 1 || journey.journeyRef.length > 200
    || typeof journey.trainNumber !== "string" || !/^(?:0|[1-9]\d{0,5})$/u.test(journey.trainNumber)
    || !instant(journey.observedAt) || !instant(journey.responseTimestamp) || !instant(journey.receivedAt)
    || Date.parse(journey.observedAt) > Date.parse(journey.responseTimestamp) + futureTolerance
    || Date.parse(journey.responseTimestamp) > Date.parse(journey.receivedAt) + futureTolerance
    || typeof journey.completeStopSequence !== "boolean" || !Array.isArray(journey.calls)
    || journey.calls.length < 1 || journey.calls.length > 4_000) return false;
  return journey.calls.every((call) => call !== null && typeof call === "object"
    && /^86\d{5}$/u.test(call.stopPointRef) && instant(call.observedAt)
    && Date.parse(call.observedAt) <= Date.parse(journey.observedAt!)
    && (call.aimedArrival === null || instant(call.aimedArrival))
    && (call.aimedDeparture === null || instant(call.aimedDeparture))
    && (call.aimedArrival !== null || call.aimedDeparture !== null)
    && (call.expectedArrival === undefined || instant(call.expectedArrival))
    && (call.expectedDeparture === undefined || instant(call.expectedDeparture))
    && (call.expectedArrival !== undefined || call.expectedDeparture !== undefined)
    && (call.conflicted === undefined || call.conflicted === true));
}

/** Atomic, bounded partial-event cache. Neither duplicate ingestion nor cleanup
 * changes a provider observation clock or the first receipt of that version. */
export class DenmarkSiriStore {
  constructor(private readonly storage: DenmarkSiriStorage, private readonly prefix = "denmark-siri:v1") {
    if (!/^[\w:-]{1,64}$/u.test(prefix)) throw new Error("Invalid Denmark SIRI storage prefix");
  }

  async ingest(xml: string, nowISO?: string): Promise<DenmarkSiriIngestResult> {
    const { deliveries: _deliveries, ignoredStale: _ignoredStale, ...result } = await this.ingestBatch([xml], nowISO);
    return result;
  }

  async ingestBatch(xml: readonly string[], nowISO?: string): Promise<DenmarkSiriBatchIngestResult> {
    if (!validDenmarkSiriBatch(xml)) throw new DenmarkSiriIngestError("Invalid Denmark SIRI batch");
    const now = nowDate(nowISO);
    const incoming: DenmarkSiriJourney[] = [];
    let ignoredStale = 0;
    for (const delivery of xml) {
      const parsed = parseDenmarkSiriDelivery(delivery, now.toISOString());
      if (parsed === null) throw new DenmarkSiriIngestError();
      if (parsed.journeys.some((journey) => Date.parse(journey.observedAt) > now.getTime() + futureTolerance)) {
        throw new DenmarkSiriIngestError("Future Denmark SIRI source timestamp");
      }
      if (parsed.journeys.length > 0 && mergeDenmarkSiriEvents([], parsed.journeys, now).length === 0) ignoredStale++;
      incoming.push(...parsed.journeys);
    }
    // Parse and validate every member before entering a durable transaction. Merge against
    // the saved identity in delivery order, then persist each final journey only once.
    const result = await this.update(now, incoming, null, true);
    return {
      outcome: ignoredStale === xml.length ? "ignored-stale"
        : result.changed ? "stored" : "unchanged",
      journeys: result.entries.length, calls: result.entries.reduce((sum, entry) => sum + entry[5], 0),
      deliveries: xml.length, ignoredStale,
    };
  }

  async readJourneys(snapshot: Pick<TripSnapshot, "serviceDate" | "product">, nowISO?: string): Promise<DenmarkSiriJourney[]> {
    const trainNumber = denmarkSiriTrainNumber(snapshot);
    const selection = date(snapshot.serviceDate) && trainNumber !== null
      ? { serviceDate: snapshot.serviceDate, trainNumber } : null;
    return (await this.update(nowDate(nowISO), [], selection, false)).journeys;
  }

  load(snapshot: Pick<TripSnapshot, "serviceDate" | "product">, nowISO?: string): Promise<DenmarkSiriJourney[]> {
    return this.readJourneys(snapshot, nowISO);
  }

  async health(nowISO?: string): Promise<DenmarkSiriHealth> {
    const result = await this.update(nowDate(nowISO), [], "all", false);
    const observed = result.journeys.map((journey) => journey.observedAt).sort();
    const received = result.journeys.map((journey) => journey.receivedAt).sort();
    const operators = {} as Record<DenmarkSiriOperatorRef, OperatorHealth>;
    for (const operatorRef of ["DSB", "DSB Vores Tog"] as const) {
      const journeys = result.journeys.filter((journey) => journey.operatorRef === operatorRef)
        .sort((left, right) => Date.parse(right.observedAt) - Date.parse(left.observedAt)
          || left.trainNumber.localeCompare(right.trainNumber) || left.journeyRef.localeCompare(right.journeyRef));
      operators[operatorRef] = {
        journeys: journeys.length, calls: journeys.reduce((sum, journey) => sum + journey.calls.length, 0),
        latestObservedAt: journeys[0]?.observedAt ?? null,
        samples: journeys.slice(0, 3).map((journey) => {
          const anchors: OperatorHealth["samples"][number]["anchors"] = [];
          for (const { stopPointRef, aimedArrival, aimedDeparture } of journey.calls) {
            if (anchors.some((anchor) => anchor.stopPointRef === stopPointRef)) continue;
            anchors.push({ stopPointRef, aimedArrival, aimedDeparture });
            if (anchors.length === 2) break;
          }
          return { trainNumber: journey.trainNumber, serviceDate: journey.serviceDate, operatorRef,
            observedAt: journey.observedAt, callCount: journey.calls.length, anchors };
        }),
      };
    }
    return { source: "denmark-siri" as const, ready: result.journeys.length > 0,
      journeys: result.journeys.length, calls: result.journeys.reduce((sum, journey) => sum + journey.calls.length, 0),
      bytes: result.entries.reduce((sum, entry) => sum + entry[3], 0),
      latestObservedAt: observed.at(-1) ?? null, oldestObservedAt: observed[0] ?? null,
      latestReceivedAt: received.at(-1) ?? null, operators };
  }

  private manifestKey(): string { return `${this.prefix}:manifest`; }
  private key(journey: DenmarkSiriJourney): string {
    return `${this.prefix}:journey:${journey.serviceDate}:${journey.trainNumber}:${hash(denmarkSiriJourneyKey(journey))}`;
  }
  private identity(entry: Entry): string { return entry[0].slice(-64); }
  private parts(entry: Entry): string[] { return Array.from({ length: entry[2] }, (_, index) => `${entry[0]}:${index}`); }
  private selected(entry: Entry, selection: Selection): boolean {
    return selection === "all" || selection !== null
      && entry[0].startsWith(`${this.prefix}:journey:${selection.serviceDate}:${selection.trainNumber}:`);
  }

  private manifest(value: unknown): Manifest {
    if (value === undefined) return { version: 1, entries: [] };
    if (typeof value !== "string" || bytes(value) > denmarkSiriStoreLimits.manifestBytes) throw new Error("Corrupt Denmark SIRI manifest");
    let candidate: Partial<Manifest>;
    try { candidate = JSON.parse(value) as Partial<Manifest>; } catch { throw new Error("Corrupt Denmark SIRI manifest"); }
    if (candidate === null || candidate.version !== 1 || !Array.isArray(candidate.entries)
      || candidate.entries.length > denmarkSiriStoreLimits.journeys) throw new Error("Corrupt Denmark SIRI manifest");
    const identities = new Set<string>();
    let total = 0;
    for (const entry of candidate.entries) {
      if (!Array.isArray(entry) || entry.length !== 6 || typeof entry[0] !== "string"
        || !entry[0].startsWith(`${this.prefix}:journey:`)
        || !/^\d{4}-\d\d-\d\d:(?:0|[1-9]\d{0,5}):[a-f0-9]{64}$/u.test(entry[0].slice(`${this.prefix}:journey:`.length))
        || !instant(entry[1]) || !Number.isInteger(entry[2]) || entry[2] < 1 || entry[2] > maximumChunks
        || !Number.isInteger(entry[3]) || entry[3] < 1 || entry[3] > denmarkSiriStoreLimits.journeyBytes
        || entry[3] < (entry[2] - 1) * denmarkSiriStoreLimits.chunkCharacters
        || typeof entry[4] !== "string" || !/^[a-f0-9]{64}$/u.test(entry[4])
        || !Number.isInteger(entry[5]) || entry[5] < 1 || entry[5] > 4_000
        || identities.has(this.identity(entry))) throw new Error("Corrupt Denmark SIRI manifest");
      identities.add(this.identity(entry)); total += entry[3];
    }
    if (total > denmarkSiriStoreLimits.bytes) throw new Error("Corrupt Denmark SIRI manifest");
    return candidate as Manifest;
  }

  private async read(transaction: SiriTransaction, entry: Entry): Promise<DenmarkSiriJourney | null> {
    const pieces: string[] = [];
    for (const key of this.parts(entry)) {
      const piece = await transaction.get<unknown>(key);
      if (typeof piece !== "string" || piece.length > denmarkSiriStoreLimits.chunkCharacters) return null;
      pieces.push(piece);
    }
    const text = pieces.join("");
    if (bytes(text) !== entry[3] || hash(text) !== entry[4]) return null;
    let journey: unknown;
    try { journey = JSON.parse(text) as unknown; } catch { return null; }
    return validJourney(journey) && this.key(journey) === entry[0] && journey.observedAt === entry[1]
      && journey.calls.length === entry[5] ? journey : null;
  }

  private async update(now: Date, incoming: DenmarkSiriJourney[], selection: Selection, persist: boolean): Promise<StateResult> {
    return this.storage.transaction(async (transaction) => {
      const before = this.manifest(await transaction.get<unknown>(this.manifestKey()));
      const retained = new Map(before.entries.filter((entry) => fresh(entry[1], now.getTime()))
        .map((entry) => [this.identity(entry), entry]));
      const events = new Map<string, DenmarkSiriJourney[]>();
      for (const journey of incoming) {
        const id = hash(denmarkSiriJourneyKey(journey));
        const deliveries = events.get(id) ?? [];
        deliveries.push(journey); events.set(id, deliveries);
      }
      const requested = new Set([...events.keys(), ...[...retained].filter(([, entry]) => this.selected(entry, selection)).map(([id]) => id)]);
      const pending = new Map<string, string>();
      const loaded = new Map<string, DenmarkSiriJourney>();
      for (const id of requested) {
        const previous = retained.get(id);
        const stored = previous === undefined ? null : await this.read(transaction, previous);
        const next = mergeDenmarkSiriEvents(stored === null ? [] : [stored], events.get(id) ?? [], now)[0];
        if (next === undefined) { retained.delete(id); continue; }
        const text = JSON.stringify(next);
        const size = bytes(text), chunks = Math.ceil(text.length / denmarkSiriStoreLimits.chunkCharacters);
        if (size > denmarkSiriStoreLimits.journeyBytes || chunks > maximumChunks) throw new DenmarkSiriIngestError("Denmark SIRI journey exceeds storage limit");
        const entry: Entry = [this.key(next), next.observedAt, chunks, size, hash(text), next.calls.length];
        retained.set(id, entry); loaded.set(id, next);
        if (stored === null || previous?.[4] !== entry[4]) pending.set(id, text);
      }
      const ordered = [...retained.values()].sort((left, right) => Date.parse(right[1]) - Date.parse(left[1]) || left[0].localeCompare(right[0]));
      const entries: Entry[] = [];
      let total = 0;
      for (const entry of ordered) {
        if (entries.length >= denmarkSiriStoreLimits.journeys || total + entry[3] > denmarkSiriStoreLimits.bytes) continue;
        entries.push(entry); total += entry[3];
      }
      let manifest = JSON.stringify({ version: 1, entries } satisfies Manifest);
      while (bytes(manifest) > denmarkSiriStoreLimits.manifestBytes) {
        entries.pop(); manifest = JSON.stringify({ version: 1, entries } satisfies Manifest);
      }
      const nextEntries = new Map(entries.map((entry) => [this.identity(entry), entry]));
      const changed = JSON.stringify(before.entries) !== JSON.stringify(entries)
        || [...pending.keys()].some((id) => nextEntries.has(id));
      // Reads filter expired/corrupt data in memory. Only ingestion persists cleanup: the
      // existing 4MiB/512-journey bounds still apply, without health checks spending writes.
      if (changed && persist) {
        for (const [id, text] of pending) {
          const entry = nextEntries.get(id);
          if (entry === undefined) continue;
          for (const [index, key] of this.parts(entry).entries()) {
            await transaction.put(key, text.slice(index * denmarkSiriStoreLimits.chunkCharacters, (index + 1) * denmarkSiriStoreLimits.chunkCharacters));
          }
        }
        const obsolete = before.entries.flatMap((previous) => {
          const next = nextEntries.get(this.identity(previous));
          return this.parts(previous).filter((_, index) => next === undefined || next[0] !== previous[0] || index >= next[2]);
        });
        for (let start = 0; start < obsolete.length; start += 100) await transaction.delete(obsolete.slice(start, start + 100));
        await transaction.put(this.manifestKey(), manifest);
      }
      return { changed, entries, journeys: entries.flatMap((entry) => {
        const journey = loaded.get(this.identity(entry));
        return journey !== undefined && this.selected(entry, selection) ? [journey] : [];
      }) };
    });
  }
}
