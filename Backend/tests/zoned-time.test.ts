import { describe, expect, it } from "vitest";
import { absoluteTime } from "../src/providers/darwin-realtime.js";
import { nearestZonedClockTime, zonedWallClockToUTC } from "../src/providers/zoned-time.js";

const iso = (value: number | null) => value === null ? null : new Date(value).toISOString();

describe("zonedWallClockToUTC", () => {
  it("uses each zone's real offset in summer and winter", () => {
    expect(iso(zonedWallClockToUTC("Europe/London", 2026, 7, 2, 10, 0))).toBe("2026-07-02T09:00:00.000Z");
    expect(iso(zonedWallClockToUTC("Europe/London", 2026, 11, 2, 10, 0))).toBe("2026-11-02T10:00:00.000Z");
    expect(iso(zonedWallClockToUTC("Europe/Paris", 2026, 11, 2, 10, 0))).toBe("2026-11-02T09:00:00.000Z");
    expect(iso(zonedWallClockToUTC("America/New_York", 2026, 11, 2, 10, 0))).toBe("2026-11-02T15:00:00.000Z");
  });

  it("resolves the repeated autumn hour to its first occurrence", () => {
    expect(iso(zonedWallClockToUTC("Europe/London", 2026, 10, 25, 1, 30))).toBe("2026-10-25T00:30:00.000Z");
  });

  it("moves a skipped spring-forward time past the gap", () => {
    expect(iso(zonedWallClockToUTC("Europe/London", 2026, 3, 29, 1, 30))).toBe("2026-03-29T01:30:00.000Z");
  });
});

describe("nearestZonedClockTime", () => {
  it("picks the next local day for a forecast after midnight", () => {
    const anchor = Date.parse("2026-11-02T23:50:00Z");
    expect(iso(nearestZonedClockTime("Europe/London", "00:20", anchor))).toBe("2026-11-03T00:20:00.000Z");
  });

  it("rejects malformed clock values", () => {
    expect(nearestZonedClockTime("Europe/London", "25:00", Date.now())).toBeNull();
    expect(nearestZonedClockTime("Europe/London", "10h45", Date.now())).toBeNull();
  });
});

describe("Darwin absoluteTime", () => {
  it("keeps winter delays over 30 minutes as late running", () => {
    expect(absoluteTime("10:45", "2026-11-02T10:00:00Z")).toBe("2026-11-02T10:45:00.000Z");
    expect(absoluteTime("11:40", "2026-11-02T10:00:00Z")).toBe("2026-11-02T11:40:00.000Z");
  });

  it("keeps summer delays over 30 minutes as late running", () => {
    expect(absoluteTime("10:45", "2026-07-02T09:00:00Z")).toBe("2026-07-02T09:45:00.000Z");
    expect(absoluteTime("11:40", "2026-07-02T09:00:00Z")).toBe("2026-07-02T10:40:00.000Z");
  });

  it("handles early running in both seasons", () => {
    expect(absoluteTime("09:20", "2026-11-02T10:00:00Z")).toBe("2026-11-02T09:20:00.000Z");
    expect(absoluteTime("09:20", "2026-07-02T09:00:00Z")).toBe("2026-07-02T08:20:00.000Z");
  });

  it("resolves forecasts across the 25 October 2026 clock change", () => {
    // Scheduled 02:10 GMT (after clocks went back), forecast 02:50 local.
    expect(absoluteTime("02:50", "2026-10-25T02:10:00Z")).toBe("2026-10-25T02:50:00.000Z");
    // Scheduled 00:40 BST, forecast 01:20 BST, still in the first 01:xx hour.
    expect(absoluteTime("01:20", "2026-10-24T23:40:00Z")).toBe("2026-10-25T00:20:00.000Z");
  });
});
