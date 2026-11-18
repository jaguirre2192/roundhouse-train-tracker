import type { BudgetStorage } from "./provider-request-budget.js";

const ledgerKey = "provider-quota:tdx-basic:v1";
const minute = 60_000;
const taipeiOffset = 8 * 60 * minute;
// Basic membership has three points per month. Leave room for account checks
// outside the Worker and respect TDX's published five requests per minute.
const monthlyRequestLimit = 2_700;
const minuteRequestLimit = 5;

interface Ledger {
  latest: number[];
  month: string;
  count: number;
  blockedUntil: number;
}

function validLedger(state: Ledger): boolean {
  return typeof state === "object" && state !== null && /^\d{4}-\d{2}$/.test(state.month)
    && Number.isSafeInteger(state.count) && state.count > 0
    && Number.isFinite(state.blockedUntil) && state.blockedUntil >= 0
    && Array.isArray(state.latest) && state.latest.length > 0 && state.latest.length <= minuteRequestLimit
    && state.latest.every((time, i) => Number.isSafeInteger(time) && time >= 0 && (i === 0 || time >= state.latest[i - 1]!));
}

function nextMonth(now: number): number {
  const local = new Date(now + taipeiOffset);
  return Date.UTC(local.getUTCFullYear(), local.getUTCMonth() + 1, 1) - taipeiOffset;
}

function retryAt(header: string | null, now: number): number {
  if (header && /^\d+$/.test(header)) {
    const resume = now + Number(header) * 1_000;
    if (Number.isSafeInteger(resume)) return Math.max(now + minute, resume);
  }
  const date = Date.parse(header ?? "");
  return Math.max(now + minute, Number.isFinite(date) ? date : 0);
}

function reserve(storage: BudgetStorage, now: number): Promise<number> {
  const month = new Date(now + taipeiOffset).toISOString().slice(0, 7);
  return storage.transaction(async tx => {
    const previous = await tx.get<Ledger>(ledgerKey);
    if (previous !== undefined && !validLedger(previous)) return now + minute;
    if (previous && previous.blockedUntil > now) return previous.blockedUntil;
    const latest = (previous?.latest ?? []).filter(t => t > now - minute);
    const last = latest.at(-1);
    if (last !== undefined && last > now) return last;
    const count = previous?.month === month ? previous.count : 0;
    if (count >= monthlyRequestLimit) return nextMonth(now);
    if (latest.length >= minuteRequestLimit) return latest[0]! + minute;
    await tx.put(ledgerKey, { month, count: count + 1, latest: [...latest, now], blockedUntil: 0 } satisfies Ledger);
    return 0;
  });
}

/** One key is shared by station boards, interactive trips and watch refreshes. */
export function tdxBudgetedFetch(
  storage: BudgetStorage, upstream: typeof fetch = (input, init) => fetch(input, init), clock = Date.now,
): typeof fetch {
  let unavailableUntil = 0;
  return async (input, init) => {
    const now = clock();
    const blocked = now < unavailableUntil ? unavailableUntil : await reserve(storage, now);
    if (blocked > 0) {
      unavailableUntil = Math.max(unavailableUntil, blocked);
      return new Response(null, {
        status: 429, headers: { "Retry-After": String(Math.max(1, Math.ceil((blocked - now) / 1_000))) },
      });
    }
    const response = await upstream(input, init);
    if (response.status !== 429) return response;
    const until = retryAt(response.headers.get("retry-after"), clock());
    unavailableUntil = Math.max(unavailableUntil, until);
    await storage.transaction(async tx => {
      const state = await tx.get<Ledger>(ledgerKey);
      if (state && validLedger(state) && state.blockedUntil < until) await tx.put(ledgerKey, { ...state, blockedUntil: until });
    });
    return response;
  };
}
