import { describe, expect, it } from "vitest";
import type { PushSender } from "../src/apns/transport.js";
import type { MaterialEvent } from "../src/domain/events.js";
import type { StopSnapshot, TripSnapshot } from "../src/domain/snapshot.js";
import { ProviderRegistry, type RailProvider } from "../src/providers/provider.js";
import { carryForwardPlatforms, collapseTripWideEvents, WatcherCycle } from "../src/worker/watcher-cycle.js";
import type { WatcherPersistence } from "../src/worker/watcher-persistence.js";

describe("WatcherCycle", () => {
  it("polls claimed trips sequentially to bound Durable Object memory", async () => {
    let activePolls = 0;
    let maximumActivePolls = 0;
    const provider: RailProvider = {
      source: "amtraker",
      discoveryScope: "us",
      searchStations: async () => [],
      fetchBoard: async () => [],
      fetchTrip: async (reference) => {
        activePolls += 1;
        maximumActivePolls = Math.max(maximumActivePolls, activePolls);
        await new Promise((resolve) => setTimeout(resolve, 1));
        activePolls -= 1;
        return {
          ...reference,
          operatorName: "Amtrak",
          product: reference.nativeId,
          headsign: "Test",
          fetchedAt: "2026-08-08T17:30:00.000Z",
          alertIds: [],
          stops: [],
        } satisfies TripSnapshot;
      },
    };
    const trips = ["171-20", "172-20"].map((nativeId) => ({
      id: `us:amtraker:${nativeId}@2026-08-08`,
      source: "amtraker" as const,
      nativeId,
      serviceDate: "2026-08-08",
      latestSnapshot: null,
    }));
    const repository: WatcherPersistence = {
      claimDueTrips: async () => trips,
      subscriptions: async () => [],
      recordSuccess: async () => {},
      recordFailure: async () => {},
      claimOutbox: async () => [],
      markDelivered: async () => {},
      markDeliveryFailed: async () => {},
      retireDevice: async () => {},
    };
    const pushSender: PushSender = { send: async () => {} };
    const cycle = new WatcherCycle(
      repository,
      new ProviderRegistry([provider]),
      pushSender,
      { info: () => {}, error: () => {} },
    );

    const report = await cycle.tick();

    expect(report.tripsClaimed).toBe(2);
    expect(report.tripsPolled).toBe(2);
    expect(maximumActivePolls).toBe(1);
  });
});

function stop(overrides: Partial<StopSnapshot> = {}): StopSnapshot {
  return {
    stationId: "eu:transitous:be-brussels-midi",
    stationName: "Brussels-Midi",
    countryCode: "BE",
    latitude: 50.8357,
    longitude: 4.3354,
    sequence: 1,
    scheduledArrival: null,
    scheduledDeparture: "2026-07-20T16:05:00.000Z",
    expectedArrival: null,
    expectedDeparture: "2026-07-20T16:05:00.000Z",
    plannedPlatform: "12",
    expectedPlatform: "12",
    platformSource: "Transitous",
    platformObservedAt: null,
    cancelled: false,
    passed: false,
    ...overrides,
  };
}

function trip(stops: StopSnapshot[]): TripSnapshot {
  return {
    id: "eu:transitous:ic-1",
    source: "transitous",
    nativeId: "ic-1",
    serviceDate: "2026-07-20",
    operatorName: "SNCB",
    product: "IC 1",
    headsign: "Oostende",
    fetchedAt: "2026-07-20T16:00:00.000Z",
    alertIds: [],
    stops,
  };
}

function event(kind: MaterialEvent["kind"], stopId: string): MaterialEvent {
  return { kind, tripId: "t", stopId, title: "", body: "", oldValue: null, newValue: "", fingerprint: `${kind}:${stopId}` };
}

describe("carryForwardPlatforms", () => {
  const overlaid = stop({ expectedPlatform: "15", platformSource: "iRail", platformObservedAt: "2026-07-20T15:59:00.000Z" });

  it("keeps the last realtime platform when the overlay returns nothing", () => {
    const current = carryForwardPlatforms(trip([overlaid]), trip([stop()]));
    expect(current.stops[0]).toMatchObject({ expectedPlatform: "15", platformSource: "iRail" });
  });

  it("prefers a fresh overlay observation", () => {
    const fresh = stop({ expectedPlatform: "3", platformSource: "iRail", platformObservedAt: "2026-07-20T16:01:00.000Z" });
    expect(carryForwardPlatforms(trip([overlaid]), trip([fresh])).stops[0]?.expectedPlatform).toBe("3");
  });

  it("drops the carried platform once the stop is passed", () => {
    const current = carryForwardPlatforms(trip([overlaid]), trip([stop({ passed: true })]));
    expect(current.stops[0]?.expectedPlatform).toBe("12");
  });
});

describe("collapseTripWideEvents", () => {
  it("keeps one delay and one cancellation but every platform change", () => {
    const events = [
      event("delay-threshold", "a"),
      event("platform-change", "a"),
      event("delay-threshold", "b"),
      event("platform-change", "b"),
      event("cancellation", "b"),
      event("cancellation", "c"),
    ];
    expect(collapseTripWideEvents(events).map((value) => value.fingerprint)).toEqual([
      "delay-threshold:a",
      "platform-change:a",
      "platform-change:b",
      "cancellation:b",
    ]);
  });
});
