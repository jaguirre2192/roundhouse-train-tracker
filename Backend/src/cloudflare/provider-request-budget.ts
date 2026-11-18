interface BudgetTransaction {
  get<T>(key: string): Promise<T | undefined>;
  put(key: string, value: unknown): Promise<void>;
}
export interface BudgetStorage {
  transaction<T>(work: (transaction: BudgetTransaction) => Promise<T>): Promise<T>;
}
type RequestLane = "trip-updates" | "positions";
interface BudgetState {
  lastReservedAt: number;
  days: Record<string, number>;
  lastLane?: RequestLane;
  laneReservedAt?: Partial<Record<RequestLane, number>>;
  blockedUntil?: number;
}

function validState(value: unknown): value is BudgetState {
  if (typeof value !== "object" || value === null) return false;
  const previous = value as BudgetState;
  return Number.isFinite(previous.lastReservedAt) && previous.lastReservedAt >= 0
    && (previous.lastLane === undefined || previous.lastLane === "trip-updates" || previous.lastLane === "positions")
    && (previous.laneReservedAt === undefined || (typeof previous.laneReservedAt === "object"
      && previous.laneReservedAt !== null && !Array.isArray(previous.laneReservedAt)
      && [Object.prototype, null].includes(Object.getPrototypeOf(previous.laneReservedAt))
      && previous.lastLane !== undefined && previous.laneReservedAt[previous.lastLane] === previous.lastReservedAt
      && Object.entries(previous.laneReservedAt).every(([lane, at]) => (lane === "trip-updates" || lane === "positions")
        && Number.isFinite(at) && at >= 0 && at <= previous.lastReservedAt)))
    && (previous.blockedUntil === undefined || (Number.isFinite(previous.blockedUntil) && previous.blockedUntil >= 0))
    && typeof previous.days === "object" && previous.days !== null && !Array.isArray(previous.days)
    && [Object.prototype, null].includes(Object.getPrototypeOf(previous.days))
    && Object.keys(previous.days).length <= 31
    && (previous.days[String(Math.floor(previous.lastReservedAt / 86_400_000))] ?? 0) > 0
    && Object.entries(previous.days).every(([key, count]) => /^\d+$/u.test(key)
      && Number.isSafeInteger(Number(key)) && String(Number(key)) === key
      && Number.isSafeInteger(count) && count >= 0);
}

/** Shared by the singleton Watcher. Retain thirty full preceding UTC days plus
 * today, so no rolling thirty-day window can exceed the provider's allowance. */
export class ProviderRequestBudget {
  constructor(
    private readonly storage: BudgetStorage,
    private readonly key: string,
    private readonly cap = 25_000,
    private readonly minimumIntervalMs = 240_000,
    private readonly now: () => number = Date.now,
    private readonly minimumLaneIntervalMs = 0,
  ) {}

  reserve(lane?: RequestLane): Promise<boolean> {
    return this.storage.transaction(async (transaction) => {
      const now = this.now(), day = Math.floor(now / 86_400_000);
      const previous = await transaction.get<BudgetState>(this.key);
      if (!Number.isFinite(now) || now < 0 || (previous !== undefined && !validState(previous))) return false;
      if (previous?.blockedUntil !== undefined && previous.blockedUntil > now) return false;
      if (previous !== undefined && now - previous.lastReservedAt < this.minimumIntervalMs) return false;
      // A per-lane cooldown allows both feeds in one poll without making
      // failures or adapter recreation a way around the key's rate limit.
      // Old shared-only ledgers migrate conservatively, retaining all counts.
      if (this.minimumLaneIntervalMs > 0 && lane === undefined) return false;
      const laneReservedAt = this.minimumLaneIntervalMs > 0 ? {
        ...(previous === undefined || previous.laneReservedAt !== undefined ? {}
          : { "trip-updates": previous.lastReservedAt, positions: previous.lastReservedAt }),
        ...previous?.laneReservedAt,
      } : undefined;
      if (lane !== undefined && laneReservedAt?.[lane] !== undefined
        && now - laneReservedAt[lane]! < this.minimumLaneIntervalMs) return false;
      // Paired feeds alternate the shared allowance even with sparse polling or
      // service recreation. Otherwise the first lane can win every refresh.
      if (lane !== undefined && previous?.lastLane === lane) return false;
      const days = Object.fromEntries(Object.entries(previous?.days ?? {})
        .filter(([key]) => Number(key) >= day - 30));
      if (Object.values(days).reduce((total, count) => total + count, 0) >= this.cap) return false;
      days[String(day)] = (days[String(day)] ?? 0) + 1;
      // Reserve before sending, including upstream errors and timeouts.
      await transaction.put(this.key, { lastReservedAt: now, days, ...(lane === undefined ? {} : { lastLane: lane }),
        ...(laneReservedAt === undefined || lane === undefined ? {} : { laneReservedAt: { ...laneReservedAt, [lane]: now } }) });
      return true;
    });
  }

  async deferUntil(until: number): Promise<void> {
    const now = this.now();
    if (!Number.isFinite(now) || !Number.isFinite(until) || until <= now) return;
    await this.storage.transaction(async (transaction) => {
      const previous = await transaction.get<BudgetState>(this.key);
      if (!validState(previous) || now < previous.lastReservedAt) throw new Error("Invalid provider cooldown state");
      await transaction.put(this.key, { ...previous, blockedUntil: Math.max(until, previous.blockedUntil ?? 0) });
    });
  }
}
