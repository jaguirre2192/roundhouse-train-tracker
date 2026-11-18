import { parseRegionalRailIndex } from "../providers/trafiklab-regional-index-schema.js";
import type { RegionalRailIndex } from "../providers/trafiklab-regional-index.js";
import { RailIndexStore } from "./rail-index-store.js";
import { parseMaintenanceDiagnostics, unknownMaintenanceDiagnostics,
  type RegionalMaintenanceDiagnostics, type ReportMaintenanceDiagnostics } from "./regional-maintenance-diagnostics.js";

export const regionalIndexMaintenanceKey = "regional-index:skane:maintenance";
type AttemptOutcome = "running" | "stored" | "unchanged" | "older" | "invalid" | "timeout" | "failed";
export interface RegionalIndexMaintenanceHealth {
  lastAttemptUTCday: string | null;
  lastAttemptAt: string | null;
  completedAt: string | null;
  outcome: AttemptOutcome | "not-attempted" | "state-invalid" | "storage-error" | "clock-invalid";
  feedVersion: string | null;
  stationCount: number | null;
  serviceCount: number | null;
  tripCount: number | null;
  diagnostics: RegionalMaintenanceDiagnostics;
  attemptsToday: number;
  previousAttempt: PreviousAttempt | null;
}
type PreviousAttempt = Omit<RegionalIndexMaintenanceHealth, "attemptsToday" | "previousAttempt">;
interface Attempt extends RegionalIndexMaintenanceHealth {
  lastAttemptUTCday: string;
  lastAttemptAt: string;
  outcome: AttemptOutcome;
}
export interface RegionalIndexPublishResult {
  outcome: "stored" | "unchanged" | "older" | "invalid";
  feedVersion?: string;
}
interface Options {
  loadIndex: (signal: AbortSignal, report: ReportMaintenanceDiagnostics) => Promise<unknown>;
  publishIndex?: (index: RegionalRailIndex, signal: AbortSignal, report: ReportMaintenanceDiagnostics) => Promise<RegionalIndexPublishResult>;
  now?: () => Date;
  notBeforeUTCMinutes?: number;
  timeoutMs?: number;
}

function empty(outcome: RegionalIndexMaintenanceHealth["outcome"] = "not-attempted"): RegionalIndexMaintenanceHealth {
  return { lastAttemptUTCday: null, lastAttemptAt: null, completedAt: null, outcome,
    feedVersion: null, stationCount: null, serviceCount: null, tripCount: null,
    diagnostics: unknownMaintenanceDiagnostics(), attemptsToday: 0, previousAttempt: null };
}
function instant(value: unknown): value is string {
  return typeof value === "string" && Number.isFinite(Date.parse(value)) && new Date(value).toISOString() === value;
}
function day(value: unknown): value is string {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/u.test(value) && instant(`${value}T00:00:00.000Z`);
}
function attemptFields(value: unknown): Omit<Attempt, "attemptsToday" | "previousAttempt"> | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const record = value as Partial<Attempt>;
  const diagnostics = parseMaintenanceDiagnostics(record.diagnostics);
  if (!day(record.lastAttemptUTCday) || !instant(record.lastAttemptAt)
    || record.lastAttemptAt.slice(0, 10) !== record.lastAttemptUTCday
    || !(record.completedAt === null || instant(record.completedAt))
    || !["running", "stored", "unchanged", "older", "invalid", "timeout", "failed"].includes(record.outcome ?? "")
    || !(record.feedVersion === null || day(record.feedVersion))
    || [record.stationCount, record.serviceCount, record.tripCount].some((count) =>
      count !== null && (!Number.isSafeInteger(count) || count! < 0)) || diagnostics === null) return null;
  // Project only known safe fields, even if persisted state contains extra data.
  return { lastAttemptUTCday: record.lastAttemptUTCday, lastAttemptAt: record.lastAttemptAt,
    completedAt: record.completedAt!, outcome: record.outcome!, feedVersion: record.feedVersion!,
    stationCount: record.stationCount!, serviceCount: record.serviceCount!, tripCount: record.tripCount!, diagnostics };
}
function attempt(value: unknown): Attempt | null {
  const fields = attemptFields(value);
  if (fields === null) return null;
  const record = value as Partial<Attempt>;
  const attemptsToday = record.attemptsToday === undefined ? 1 : record.attemptsToday;
  if (attemptsToday !== 1 && attemptsToday !== 2) return null;
  const previousAttempt = record.previousAttempt == null ? null : attemptFields(record.previousAttempt);
  if (record.previousAttempt != null && (previousAttempt === null
    || !["failed", "timeout"].includes(previousAttempt.outcome)
    || previousAttempt.lastAttemptUTCday > fields.lastAttemptUTCday)) return null;
  if (attemptsToday === 2 && (previousAttempt === null || previousAttempt.lastAttemptUTCday !== fields.lastAttemptUTCday)) return null;
  return { ...fields, attemptsToday, previousAttempt };
}
function previousAttempt(value: Attempt): PreviousAttempt {
  const { attemptsToday: _count, previousAttempt: _previous, ...fields } = value;
  return fields;
}

export class RegionalIndexRetryRejected extends Error {
  constructor() { super("Regional index retry is not allowed"); this.name = "RegionalIndexRetryRejected"; }
}

/** One reserved attempt per UTC day, including failed or interrupted downloads. */
export class RegionalIndexMaintenance {
  private pending: Promise<RegionalIndexMaintenanceHealth> | null = null;
  private readonly now: () => Date;
  private readonly notBefore: number;
  private readonly timeoutMs: number;
  private readonly indexStore: RailIndexStore;

  constructor(private readonly storage: DurableObjectStorage, private readonly options: Options) {
    this.now = options.now ?? (() => new Date());
    this.notBefore = options.notBeforeUTCMinutes ?? 8 * 60 + 43;
    if (!Number.isInteger(this.notBefore) || this.notBefore < 0 || this.notBefore >= 24 * 60) {
      throw new RangeError("Invalid regional index maintenance UTC start minute");
    }
    this.timeoutMs = Number.isFinite(options.timeoutMs) ? Math.min(120_000, Math.max(1, options.timeoutMs!)) : 120_000;
    this.indexStore = new RailIndexStore(storage, this.now);
  }

  async health(): Promise<RegionalIndexMaintenanceHealth> {
    try {
      const value = await this.storage.get<unknown>(regionalIndexMaintenanceKey);
      return value === undefined ? empty() : attempt(value) ?? empty("state-invalid");
    } catch { return empty("storage-error"); }
  }

  run(retryFailedAttemptAt?: string): Promise<RegionalIndexMaintenanceHealth> {
    if (this.pending !== null) return retryFailedAttemptAt === undefined ? this.pending : Promise.reject(new RegionalIndexRetryRejected());
    const request = this.execute(retryFailedAttemptAt).finally(() => { if (this.pending === request) this.pending = null; });
    this.pending = request;
    return request;
  }

  private async execute(retryFailedAttemptAt?: string): Promise<RegionalIndexMaintenanceHealth> {
    let reserved: Attempt;
    try {
      const gate = await this.storage.transaction(async (transaction) => {
        const value = await transaction.get<unknown>(regionalIndexMaintenanceKey);
        const previous = value === undefined ? null : attempt(value);
        if (value !== undefined && previous === null) {
          if (retryFailedAttemptAt !== undefined) throw new RegionalIndexRetryRejected();
          return { allowed: false, health: empty("state-invalid") };
        }
        const now = this.now();
        if (!Number.isFinite(now.getTime()) || now.getTime() < 0) {
          if (retryFailedAttemptAt !== undefined) throw new RegionalIndexRetryRejected();
          return { allowed: false, health: empty("clock-invalid") };
        }
        const utcDay = now.toISOString().slice(0, 10);
        const retry = retryFailedAttemptAt !== undefined;
        if (retry && (!instant(retryFailedAttemptAt) || previous === null
          || previous.lastAttemptUTCday !== utcDay || previous.lastAttemptAt !== retryFailedAttemptAt
          || !["failed", "timeout"].includes(previous.outcome) || previous.attemptsToday !== 1
          || now.getTime() < Date.parse(previous.lastAttemptAt))) throw new RegionalIndexRetryRejected();
        if (!retry && (now.getUTCHours() * 60 + now.getUTCMinutes() < this.notBefore
          || (previous !== null && previous.lastAttemptUTCday >= utcDay))) {
          return { allowed: false, health: previous ?? empty() };
        }
        const next: Attempt = { ...empty(), lastAttemptUTCday: utcDay,
          lastAttemptAt: now.toISOString(), outcome: "running",
          attemptsToday: retry ? 2 : 1,
          previousAttempt: retry ? previousAttempt(previous!) : previous?.previousAttempt ?? null,
          diagnostics: { ...unknownMaintenanceDiagnostics(), phase: "reserved", downloadBytes: 0, downloadComplete: false } };
        await transaction.put(regionalIndexMaintenanceKey, next);
        return { allowed: true, health: next };
      });
      if (!gate.allowed) return gate.health;
      reserved = gate.health as Attempt;
    } catch (error) {
      if (error instanceof RegionalIndexRetryRejected) throw error;
      return empty("storage-error");
    }

    const result: Attempt = { ...reserved };
    let acceptingDiagnostics = true;
    const report: ReportMaintenanceDiagnostics = (update) => {
      if (!acceptingDiagnostics) return;
      const checked = parseMaintenanceDiagnostics({ ...result.diagnostics, ...update });
      if (checked !== null) result.diagnostics = checked;
    };
    const controller = new AbortController();
    let timedOut = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const work = async (): Promise<Partial<Attempt>> => {
        const value = await this.options.loadIndex(controller.signal, report);
        controller.signal.throwIfAborted();
        report({ phase: "validation" });
        const index = parseRegionalRailIndex(value, this.now());
        if (index === null) return { outcome: "invalid" };
        report({ phase: "publish-request", httpStatus: null, redirectStatus: null });
        const saved = await (this.options.publishIndex?.(index, controller.signal, report) ?? this.indexStore.save(index));
        return { outcome: saved.outcome, feedVersion: saved.feedVersion ?? null,
          ...(saved.outcome === "stored" || saved.outcome === "unchanged" ? {
            stationCount: index.stations.length, serviceCount: index.services.length, tripCount: index.trips.length,
          } : {}) };
      };
      const finished = await Promise.race([
        Promise.resolve().then(work),
        new Promise<never>((_resolve, reject) => {
          timer = setTimeout(() => {
            timedOut = true;
            controller.abort();
            reject(new Error("Regional index maintenance timed out"));
          }, this.timeoutMs);
        }),
      ]);
      Object.assign(result, finished);
    } catch { result.outcome = timedOut ? "timeout" : "failed"; }
    finally { acceptingDiagnostics = false; clearTimeout(timer); }
    const completed = this.now();
    result.completedAt = Number.isFinite(completed.getTime()) && completed.getTime() >= Date.parse(reserved.lastAttemptAt)
      ? completed.toISOString() : null;
    try {
      await this.storage.transaction(async (transaction) => {
        const current = attempt(await transaction.get<unknown>(regionalIndexMaintenanceKey));
        if (current?.lastAttemptAt === reserved.lastAttemptAt && current.outcome === "running") {
          await transaction.put(regionalIndexMaintenanceKey, result);
        }
      });
    } catch { /* The reservation already persists; never retry today's download. */ }
    return result;
  }
}
