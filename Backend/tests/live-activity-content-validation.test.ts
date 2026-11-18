import { describe, expect, it } from "vitest";
import { parseLiveActivityContent, parseLiveActivityRegistration } from "../src/cloudflare/live-activity-validation.js";

const base = {
  schemaVersion: 1, phase: "upcoming", focusName: "Washington Union", eventTime: null, timeZoneIdentifier: null,
  timingBasis: "unavailable", platform: "17", platformBasis: "reported", platformChanged: false, delayMinutes: null,
  checkedAt: null, validUntil: 1_789_507_680, isStopCancelled: false,
};

describe("Live Activity content validation", () => {
  it("accepts content from apps that predate the optional platform fields", () => {
    const parsed = parseLiveActivityContent(base);
    expect(parsed).not.toHaveProperty("platformKind");
    expect(parsed).not.toHaveProperty("platformSource");
    expect(parsed).not.toHaveProperty("boardingPlatformSequence");
  });

  it("round trips only a valid reported boarding call for the departure sign", () => {
    const sign = { ...base, phase: "departureSoon", eventTime: base.validUntil + 900, boardingPlatformSequence: 4 };
    expect(parseLiveActivityContent(sign).boardingPlatformSequence).toBe(4);
    expect(parseLiveActivityContent({ ...sign, phase: "upcoming" }).boardingPlatformSequence).toBe(4);
    expect(parseLiveActivityContent({ ...sign, phase: "underway" })).not.toHaveProperty("boardingPlatformSequence");
    expect(parseLiveActivityContent({ ...sign, platformBasis: "predicted" })).not.toHaveProperty("boardingPlatformSequence");
    expect(() => parseLiveActivityContent({ ...sign, boardingPlatformSequence: -1 })).toThrow();
  });

  it("retains a watcher's choice while accepting older registrations", () => {
    const input = { schemaVersion: 1, installationId: "4deeabaa-03af-4ab0-a804-d7786d74582e", activityId: "boarding-test",
      token: "a".repeat(64), environment: "sandbox", tokenGeneration: 1,
      trip: { id: "us:amtraker:171-20", source: "amtraker", nativeId: "171-20", serviceDate: "2026-09-07" },
      boardingStationId: "NYP", alightingStationId: "WAS", boardingStopSequence: 1, alightingStopSequence: 2,
      startedAt: "2026-09-07T10:20:00Z", initialContentState: base };
    expect(parseLiveActivityRegistration({ ...input, isRiding: false }).isRiding).toBe(false);
    expect(parseLiveActivityRegistration(input)).not.toHaveProperty("isRiding");
    expect(() => parseLiveActivityRegistration({ ...input, isRiding: "false" })).toThrow();
  });

  it("keeps a valid track kind and source and rejects an unknown kind", () => {
    expect(parseLiveActivityContent({ ...base, platformKind: "track", platformSource: "Amtraker" }))
      .toMatchObject({ platformKind: "track", platformSource: "Amtraker" });
    expect(() => parseLiveActivityContent({ ...base, platformKind: "gate" })).toThrow();
    expect(parseLiveActivityContent({ ...base, platform: null, platformBasis: "unavailable", platformSource: "Amtraker" }))
      .not.toHaveProperty("platformSource");
  });
});
