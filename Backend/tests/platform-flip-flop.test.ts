import { describe, expect, it } from "vitest";
import { diffSnapshots } from "../src/domain/events.js";
import { defaultPushPreferences, type TripSnapshot } from "../src/domain/snapshot.js";
import {
  TripSnapshotEnricher,
  type PlatformObservation,
  type PlatformRealtimeOverlay,
} from "../src/providers/platform-overlay.js";
import { carryForwardPlatforms } from "../src/worker/watcher-cycle.js";

function base(fetchedAt: string): TripSnapshot {
  return {
    id: "eu:transitous:gb-test-1",
    source: "transitous",
    nativeId: "gb-test-1",
    serviceDate: "2026-07-21",
    operatorName: "GWR",
    product: "GWR",
    headsign: "Bristol Temple Meads",
    fetchedAt,
    alertIds: [],
    stops: [{
      stationId: "eu:transitous:gb-test-reading",
      stationName: "Reading",
      countryCode: "GB",
      latitude: 51.459,
      longitude: -0.972,
      sequence: 1,
      scheduledArrival: null,
      scheduledDeparture: "2026-07-21T21:29:00.000Z",
      expectedArrival: null,
      expectedDeparture: "2026-07-21T21:29:00.000Z",
      plannedPlatform: "8",
      expectedPlatform: "8",
      platformSource: "Transitous",
      platformObservedAt: null,
      cancelled: false,
      passed: false,
    }],
  };
}

type Cycle = "platform-9" | "failed" | "empty" | "suppressed";

function overlay(cycle: () => Cycle, observedAt: () => string): PlatformRealtimeOverlay {
  return {
    sourceName: "Test realtime",
    supportedCountryCodes: new Set(["GB"]),
    async platformUpdates(): Promise<PlatformObservation[]> {
      const value = cycle();
      if (value === "failed") throw new Error("fetch failed");
      if (value === "empty") return [];
      return [{
        stopSequence: 1,
        stationId: "eu:transitous:gb-test-reading",
        ...(value === "suppressed"
          ? { expectedPlatform: null, platformSuppressed: true }
          : { expectedPlatform: "9" }),
        observedAt: observedAt(),
        source: "Test realtime",
      }];
    },
  };
}

async function run(cycles: Cycle[]): Promise<string[]> {
  let index = 0;
  let observedAt = "";
  const enricher = new TripSnapshotEnricher([overlay(() => cycles[index]!, () => observedAt)]);
  // The rider first saw the timetable platform before any realtime arrived.
  let previous: TripSnapshot = base("2026-07-21T20:59:00.000Z");
  const announced: string[] = [];
  for (index = 0; index < cycles.length; index += 1) {
    const fetchedAt = new Date(Date.UTC(2026, 6, 21, 21, index)).toISOString();
    observedAt = fetchedAt;
    const current = carryForwardPlatforms(previous, await enricher.enrich(base(fetchedAt)));
    announced.push(...diffSnapshots(previous, current, defaultPushPreferences)
      .filter((event) => event.kind === "platform-change")
      .map((event) => `${event.oldValue}->${event.newValue}`));
    previous = current;
  }
  return announced;
}

describe("platform flip-flop protection", () => {
  it.each<Cycle>(["failed", "empty"])(
    "announces a realtime platform once when the overlay later goes %s",
    async (gap) => {
      await expect(run(["platform-9", gap, "platform-9", gap, "platform-9"])).resolves.toEqual(["8->9"]);
    },
  );

  it("hides a suppressed platform silently and announces it again when it is revealed", async () => {
    // Operators hold platforms back at busy termini; the reveal is what riders wait for.
    await expect(run(["platform-9", "suppressed", "platform-9"])).resolves.toEqual(["8->9", "null->9"]);
  });

  it("treats a lost realtime platform as unknown even without the watcher carry-forward", async () => {
    const enricher = new TripSnapshotEnricher([overlay(() => "platform-9", () => "2026-07-21T21:00:00.000Z")]);
    const previous = await enricher.enrich(base("2026-07-21T21:00:00.000Z"));
    const failed = await new TripSnapshotEnricher([overlay(() => "failed", () => "")])
      .enrich(base("2026-07-21T21:01:00.000Z"));
    const suppressed = await new TripSnapshotEnricher([overlay(() => "suppressed", () => "2026-07-21T21:01:00.000Z")])
      .enrich(base("2026-07-21T21:01:00.000Z"));

    expect(diffSnapshots(previous, failed, defaultPushPreferences)).toEqual([]);
    expect(diffSnapshots(previous, suppressed, defaultPushPreferences)).toEqual([]);
  });

  it("does not mint a new fingerprint just because the observation time moved", () => {
    const previous = base("2026-07-21T21:00:00.000Z");
    const observed = (platformObservedAt: string) => {
      const current = base("2026-07-21T21:01:00.000Z");
      current.stops[0] = { ...current.stops[0]!, expectedPlatform: "9", platformObservedAt };
      return current;
    };

    const first = diffSnapshots(previous, observed("2026-07-21T21:00:30.000Z"), defaultPushPreferences);
    const retried = diffSnapshots(previous, observed("2026-07-21T21:00:50.000Z"), defaultPushPreferences);

    expect(first).toHaveLength(1);
    expect(retried[0]?.fingerprint).toBe(first[0]?.fingerprint);
  });
});
