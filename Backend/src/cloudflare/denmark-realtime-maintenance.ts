import type { DenmarkBusClient } from "../providers/denmark-servicebus-http.js";
import type { DenmarkBatchPublishResult } from "./denmark-realtime-publish.js";
import { drainDenmarkMessages } from "./denmark-realtime-batch.js";
import { denmarkMaximumMessages, denmarkPaidMaximumMessages, denmarkPollKey, validDenmarkPollState, type DenmarkPollState } from "./denmark-realtime-poll-state.js";
import { denmarkOperation } from "../providers/denmark-servicebus-request.js";

export type { DenmarkPollState } from "./denmark-realtime-poll-state.js";
interface Transaction {
  getAlarm(): Promise<number | null>;
  put(key: string, value: unknown): Promise<void>;
  setAlarm(at: number): Promise<void>;
}
export interface DenmarkPollStorage {
  get<T>(key: string): Promise<T | undefined>;
  transaction<T>(work: (tx: Transaction) => Promise<T>): Promise<T>;
}
const emptyCheckpointIntervalMs = 60_000;

/** Only the native DO alarm may drain the broker. Its at-least-once delivery
 * and single-handler guarantee replace a second application-level lease.
 * RPC/cron calls only wake it; a watchdog recovers exhausted native retries. */
export class DenmarkRealtimeMaintenance {
  private loaded: Promise<void> | null = null;
  private latest: DenmarkPollState | null = null;
  private checkpoint: DenmarkPollState | null = null;
  private current: DenmarkPollState | null = null;
  private corrupt = false;
  private active = false;

  constructor(private readonly storage: DenmarkPollStorage, private readonly bus: DenmarkBusClient | null,
    private readonly publish: (bytes: readonly Uint8Array[], signal: AbortSignal) => Promise<DenmarkBatchPublishResult>,
    private readonly now: () => number = () => Date.now(),
    private readonly maximumMessages = denmarkMaximumMessages) {
    if (!Number.isSafeInteger(maximumMessages) || maximumMessages < 1 || maximumMessages > denmarkPaidMaximumMessages) {
      throw new Error("Invalid Denmark consumer work bound");
    }
  }

  private load(): Promise<void> {
    return this.loaded ??= this.storage.get<unknown>(denmarkPollKey).then(value => {
      this.corrupt = value !== undefined && !validDenmarkPollState(value);
      this.latest = this.checkpoint = validDenmarkPollState(value) ? value : null;
    }).catch(error => { this.loaded = null; throw error; });
  }

  async health() {
    await this.load();
    return { configured: this.bus !== null, maintenance: structuredClone(this.current ?? this.latest), corruptState: this.corrupt };
  }

  /** An existing pending alarm or running handler already owns the wakeup.
   * Repeated watchdog calls never rewrite its deadline or start broker work. */
  async wake() {
    if (this.bus === null) return { wakeScheduled: false };
    await this.load();
    if (this.corrupt || !Number.isFinite(this.now()) || this.now() < 0) return { wakeScheduled: false };
    const wakeScheduled = await this.storage.transaction(async tx => {
      if (this.active || await tx.getAlarm() !== null || this.active) return true;
      await tx.setAlarm(Math.max(this.now(), this.dueAt()));
      return true;
    });
    return { wakeScheduled };
  }

  /** Internal alarm entry; never expose this method through an HTTP/RPC route. */
  async runAlarm() {
    if (this.active) return { ...(await this.health()), started: false };
    this.active = true;
    try {
      await this.load();
      const now = this.now();
      if (this.bus === null || this.corrupt || !Number.isFinite(now) || now < 0) {
        return { ...(await this.health()), started: false };
      }
      // Honor an in-flight lease written by the previous deployed version.
      const due = this.dueAt();
      if (now < due) {
        await this.storage.transaction(async tx => {
          if (await tx.getAlarm() !== due) await tx.setAlarm(due);
        });
        return { ...(await this.health()), started: false };
      }
      const state: DenmarkPollState = { reservedAt: now, leaseUntil: now + 55_000, finishedAt: null,
        nextDueAt: now + 55_000, outcome: "running", received: 0, completed: 0, abandoned: 0,
        ignoredStale: 0, durationMs: null, backlog: "unknown", phase: null, failure: null, httpStatus: null };
      this.current = state;
      await drainDenmarkMessages(state, this.bus, this.publish, this.now, this.maximumMessages);
      state.finishedAt = this.now();
      state.durationMs = Math.max(0, state.finishedAt - state.reservedAt);
      const backoff = state.outcome === "failed" ? state.httpStatus === 429 ? 60_000 : 30_000
        : state.backlog === "empty" ? 10_000 : 1_000;
      state.nextDueAt = state.finishedAt + backoff;
      const persist = this.shouldCheckpoint(state);
      // A failed commit throws out of alarm(), retaining native retry behavior.
      // Broker settlement already depended on the API's separate durable ACK.
      await this.storage.transaction(async tx => {
        if (persist) await tx.put(denmarkPollKey, state);
        if (await tx.getAlarm() !== state.nextDueAt) await tx.setAlarm(state.nextDueAt);
      });
      this.latest = state;
      if (persist) this.checkpoint = state;
      return { ...(await this.health()), started: true };
    } finally {
      // Do not keep an AMQP socket (and billable DO duration) alive between polls.
      // Failed cleanup retains the broker's original lock-expiry recovery path.
      if (this.bus?.close !== undefined) {
        await denmarkOperation("abandon", undefined, 3_000, () => this.bus!.close!()).catch(() => undefined);
      }
      this.current = null;
      this.active = false;
    }
  }

  private dueAt(): number {
    return this.latest === null ? 0 : this.latest.outcome === "running" ? this.latest.leaseUntil : this.latest.nextDueAt;
  }

  private shouldCheckpoint(state: DenmarkPollState): boolean {
    return state.outcome !== "empty" || state.received > 0 || this.checkpoint?.outcome !== "empty"
      || this.checkpoint.received > 0 || this.checkpoint.finishedAt === null
      || state.finishedAt! - this.checkpoint.finishedAt >= emptyCheckpointIntervalMs;
  }
}
