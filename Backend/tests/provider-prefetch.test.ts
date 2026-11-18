import { describe, expect, it } from "vitest";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { ProviderRegistry, type RailProvider } from "../src/providers/provider.js";
import { TripSnapshotEnricher, type PlatformRealtimeOverlay } from "../src/providers/platform-overlay.js";

const trip: TripSnapshot = {
  id: "eu:transitous:fr-cold", nativeId: "fr-cold", source: "transitous", serviceDate: "2026-11-13",
  operatorName: "SNCF", product: "TER 1", headsign: "Nice", fetchedAt: "2026-11-13T21:00:00Z",
  stops: [], alertIds: [],
};
const provider = (fetchTrip: RailProvider["fetchTrip"]): RailProvider => ({
  source: "transitous", discoveryScope: "international", searchStations: async () => [], fetchBoard: async () => [], fetchTrip,
});

describe("optional provider warming", () => {
  it("overlaps a cold source with base resolution and keeps it alive without delaying available data", async () => {
    let releaseBase!: (value: TripSnapshot) => void;
    let finishWarm!: () => void;
    let warmStarted = false;
    const keptAlive: Promise<unknown>[] = [];
    const overlay: PlatformRealtimeOverlay = {
      sourceName: "Cold source", supportedCountryCodes: new Set(["FR"]), platformUpdates: async () => [],
      prefetch: async () => { warmStarted = true; await new Promise<void>((resolve) => { finishWarm = resolve; }); },
    };
    const registry = new ProviderRegistry([provider(() => new Promise((resolve) => { releaseBase = resolve; }))],
      new TripSnapshotEnricher([overlay]), (work) => keptAlive.push(work));
    const pending = registry.fetchTrip(trip);
    await Promise.resolve();
    expect(warmStarted).toBe(true);
    expect(keptAlive).toHaveLength(1);
    releaseBase(trip);
    await expect(pending).resolves.toEqual(trip);
    finishWarm();
    await Promise.all(keptAlive);
  });

  it("isolates synchronous and asynchronous warm failures from the base trip", async () => {
    const overlays = [
      () => { throw new Error("cold source failed"); },
      async () => { throw new Error("network failed"); },
    ].map((prefetch): PlatformRealtimeOverlay => ({ sourceName: "Unavailable", supportedCountryCodes: new Set(["FR"]),
      platformUpdates: async () => [], prefetch }));
    const keptAlive: Promise<unknown>[] = [];
    const registry = new ProviderRegistry([provider(async () => trip)], new TripSnapshotEnricher(overlays),
      (work) => keptAlive.push(work));
    await expect(registry.fetchTrip(trip)).resolves.toEqual(trip);
    await expect(Promise.all(keptAlive)).resolves.toEqual([undefined]);
  });
});
