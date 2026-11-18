import { arrivalReport, boardView, fallbackExpiry, makeBoardRecord, selectedCall,
  type ArrivalBoardRequest, type ArrivalReport } from "../domain/arrival-board.js";
import type { CanonicalTripReference, TripSnapshot } from "../domain/snapshot.js";
import { FixedWindowRateLimiter } from "../services/journey-rate-limiter.js";
import { ArrivalBoardStore } from "./arrival-board-store.js";

type SnapshotReader = (ref: CanonicalTripReference, clientKey: string) => Promise<TripSnapshot>;

export class ArrivalBoardService {
  private readonly store: ArrivalBoardStore;
  private readonly limiter = new FixedWindowRateLimiter({ create: 6, read: 90 });

  constructor(sql: SqlStorage, private readonly snapshot: SnapshotReader) { this.store = new ArrivalBoardStore(sql); }

  async create(input: ArrivalBoardRequest, clientKey: string) {
    this.limiter.consume("create", clientKey);
    let snapshot: TripSnapshot;
    try { snapshot = await this.snapshot(input.trip, clientKey); }
    catch (error) {
      if (error instanceof Error && error.name === "RateLimitExceededError") throw error;
      return { outcome: "unavailable" } as const;
    }
    const now = Date.now();
    const stop = selectedCall(snapshot, input);
    if (!stop || stop.cancelled) return { outcome: "invalid_stop" } as const;
    const expiry = fallbackExpiry(stop, now, snapshot.fetchedAt);
    const report = arrivalReport(stop, now);
    if (expiry === null) return { outcome: "invalid_stop" } as const;
    if (expiry <= now || report) return { outcome: "ended" } as const;
    const token = await this.store.create(makeBoardRecord(input, snapshot, stop), expiry);
    return { outcome: "created", token, expiresAt: new Date(expiry).toISOString() } as const;
  }

  async read(token: string, clientKey: string) {
    this.limiter.consume("read", clientKey);
    const entry = await this.store.load(token, Date.now());
    if (!entry) return null;
    let snapshot: TripSnapshot | null = null;
    if (!entry.row.settled) {
      try { snapshot = await this.snapshot(entry.record.trip, clientKey); }
      catch (error) {
        if (error instanceof Error && error.name === "RateLimitExceededError") throw error;
        // The verified saved station and timetable remain available through an outage.
      }
    }
    const now = Date.now();
    const stop = snapshot ? selectedCall(snapshot, entry.record) : null;
    const report = stop ? arrivalReport(stop, now) : null;
    if (report) this.store.settle(entry.hash, report);
    // A concurrent request may have confirmed arrival or this request may have straddled expiry.
    const current = this.store.row(entry.hash, now);
    if (!current) return null;
    const settled: ArrivalReport | null = current.settled && current.kind ? { kind: current.kind, observedAt: current.settled } : null;
    return boardView(entry.record, stop, snapshot?.fetchedAt ?? null, settled, current.expires, now);
  }

  prune(): void { this.store.prune(Date.now()); }
}
