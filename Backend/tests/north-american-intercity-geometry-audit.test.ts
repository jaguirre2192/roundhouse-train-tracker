import { describe, expect, it } from "vitest";
import {
  allowedNorthAmericanIntercityGeometryMisses,
  evaluateNorthAmericanIntercityGeometryAudit,
  type NorthAmericanIntercityGeometryAuditCount,
} from "../src/providers/north-american-intercity-geometry-audit.js";

const enabledOperators = ["amtrak", "brightline", "via"] as const;

function counts(
  entries: Record<string, NorthAmericanIntercityGeometryAuditCount>,
): Map<string, NorthAmericanIntercityGeometryAuditCount> {
  return new Map(Object.entries(entries));
}

describe("evaluateNorthAmericanIntercityGeometryAudit", () => {
  it("passes with warnings for the handful of unjoinable live trains seen on main (Oct 30 2026)", () => {
    const result = evaluateNorthAmericanIntercityGeometryAudit(counts({
      amtrak: { total: 142, matched: 140, misses: ["2152-30:2152", "2155-30:2155"] },
      brightline: { total: 9, matched: 9, misses: [] },
      via: { total: 40, matched: 40, misses: [] },
    }), enabledOperators);

    expect(result.passed).toBe(true);
    expect(result.failures).toEqual([]);
    expect(result.warnings).toEqual([
      "amtrak: 2 of 142 live trains have no GTFS geometry (allowed 14): 2152-30:2152, 2155-30:2155",
    ]);
  });

  it("tolerates the worst day of October 2026 (12 Amtrak misses of 138)", () => {
    const misses = ["87", "99", "152", "380", "765", "1078", "1079", "1094", "1098", "1180", "1471", "1479"];
    const result = evaluateNorthAmericanIntercityGeometryAudit(counts({
      amtrak: { total: 138, matched: 126, misses },
      brightline: { total: 10, matched: 10, misses: [] },
      via: { total: 29, matched: 29, misses: [] },
    }), enabledOperators);

    expect(result.passed).toBe(true);
    expect(result.warnings).toHaveLength(1);
  });

  it("allows one miss on a small fleet", () => {
    const result = evaluateNorthAmericanIntercityGeometryAudit(counts({
      amtrak: { total: 142, matched: 141, misses: ["821-9:821"] },
      brightline: { total: 9, matched: 8, misses: ["B5137-9:B5137"] },
      via: { total: 41, matched: 40, misses: ["v663-9:v663"] },
    }), enabledOperators);

    expect(result.passed).toBe(true);
    expect(result.warnings).toHaveLength(3);
  });

  it("fails when coverage drops broadly, as a broken catalog join would", () => {
    const result = evaluateNorthAmericanIntercityGeometryAudit(counts({
      amtrak: { total: 140, matched: 70, misses: Array.from({ length: 70 }, (_, index) => `${index}`) },
      brightline: { total: 10, matched: 10, misses: [] },
      via: { total: 40, matched: 40, misses: [] },
    }), enabledOperators);

    expect(result.passed).toBe(false);
    expect(result.failures).toHaveLength(1);
    expect(result.failures[0]).toMatch(/^amtrak: 70 of 140 live trains have no GTFS geometry \(allowed 14\)/u);
  });

  it("warns when a smaller operator has no live trains to audit", () => {
    const result = evaluateNorthAmericanIntercityGeometryAudit(counts({
      amtrak: { total: 140, matched: 140, misses: [] },
      via: { total: 40, matched: 40, misses: [] },
    }), enabledOperators);

    expect(result.passed).toBe(true);
    expect(result.warnings).toEqual(["brightline: no live trains reported, so none were audited"]);
  });

  it("fails when Amtrak has no live trains to audit", () => {
    const result = evaluateNorthAmericanIntercityGeometryAudit(counts({
      brightline: { total: 20, matched: 20, misses: [] },
      via: { total: 40, matched: 40, misses: [] },
    }), enabledOperators);

    expect(result.passed).toBe(false);
    expect(result.failures).toEqual(["amtrak: no live trains to audit"]);
  });

  it("scales the allowance with fleet size", () => {
    expect(allowedNorthAmericanIntercityGeometryMisses(9)).toBe(2);
    expect(allowedNorthAmericanIntercityGeometryMisses(40)).toBe(4);
    expect(allowedNorthAmericanIntercityGeometryMisses(142)).toBe(14);
  });
});
