import type { NorthAmericanIntercityOperator } from "./north-american-intercity-gtfs-model.js";

export interface NorthAmericanIntercityGeometryAuditCount {
  total: number;
  matched: number;
  misses: string[];
}

export interface NorthAmericanIntercityGeometryAuditTolerance {
  maxMissRate: number;
  minAllowedMisses: number;
  /** Operators whose live board must never be empty; others only warn. */
  requiredLiveOperators: readonly NorthAmericanIntercityOperator[];
}

export interface NorthAmericanIntercityGeometryAuditResult {
  passed: boolean;
  failures: string[];
  warnings: string[];
}

// Live boards always carry a few trains the static timetable cannot join (extras,
// overnight trains from the previous service day, trains between feed versions),
// so only a broad drop in coverage should fail the scheduled check.
// An empty live board for a small operator usually means the live source left it
// out for a while (it happened for Brightline on Nov 3, 2026), not that the
// catalog broke; the script checks separately that every operator is in the
// catalog. Amtrak always has trains running, so an empty Amtrak board still fails.
export const defaultNorthAmericanIntercityGeometryAuditTolerance: NorthAmericanIntercityGeometryAuditTolerance = {
  maxMissRate: 0.1,
  minAllowedMisses: 2,
  requiredLiveOperators: ["amtrak"],
};

export function allowedNorthAmericanIntercityGeometryMisses(
  total: number,
  tolerance: NorthAmericanIntercityGeometryAuditTolerance = defaultNorthAmericanIntercityGeometryAuditTolerance,
): number {
  return Math.max(tolerance.minAllowedMisses, Math.floor(total * tolerance.maxMissRate));
}

export function evaluateNorthAmericanIntercityGeometryAudit(
  counts: ReadonlyMap<string, NorthAmericanIntercityGeometryAuditCount>,
  enabledOperators: readonly NorthAmericanIntercityOperator[],
  tolerance: NorthAmericanIntercityGeometryAuditTolerance = defaultNorthAmericanIntercityGeometryAuditTolerance,
): NorthAmericanIntercityGeometryAuditResult {
  const failures: string[] = [];
  const warnings: string[] = [];
  for (const operator of enabledOperators) {
    const count = counts.get(operator);
    if (count === undefined || count.total === 0) {
      if (tolerance.requiredLiveOperators.includes(operator)) {
        failures.push(`${operator}: no live trains to audit`);
      } else {
        warnings.push(`${operator}: no live trains reported, so none were audited`);
      }
      continue;
    }
    const misses = count.total - count.matched;
    if (misses === 0) continue;
    const allowed = allowedNorthAmericanIntercityGeometryMisses(count.total, tolerance);
    const message = `${operator}: ${misses} of ${count.total} live trains have no GTFS geometry `
      + `(allowed ${allowed}): ${count.misses.join(", ")}`;
    if (misses > allowed) failures.push(message);
    else warnings.push(message);
  }
  return { passed: failures.length === 0, failures, warnings };
}
