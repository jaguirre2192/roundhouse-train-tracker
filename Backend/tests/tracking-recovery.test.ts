import { describe, expect, it } from "vitest";
import { defaultPushPreferences, type StopSnapshot, type TripSnapshot } from "../src/domain/snapshot.js";
import { diffSnapshots } from "../src/domain/events.js";
import { IRailPlatformOverlay } from "../src/providers/irail.js";
import { TripSnapshotEnricher } from "../src/providers/platform-overlay.js";
import { ProviderRegistry } from "../src/providers/provider.js";
import { TransitousProvider } from "../src/providers/transitous.js";
import { carryForwardPlatforms } from "../src/worker/watcher-cycle.js";

function stop(stationId: string, sequence: number, overrides: Partial<StopSnapshot> = {}): StopSnapshot {
  return { stationId, stationName: stationId, sequence, countryCode: "BE", latitude: 50.8, longitude: 4.3,
    scheduledArrival: null, scheduledDeparture: "2026-11-12T10:00:00Z", expectedArrival: null,
    expectedDeparture: "2026-11-12T10:00:00Z", plannedPlatform: "2", expectedPlatform: "2",
    platformSource: "Transitous", platformObservedAt: null, passed: false, cancelled: false, ...overrides };
}
function trip(stops: StopSnapshot[]): TripSnapshot {
  return { id: "test", source: "transitous", nativeId: "test-531", serviceDate: "2026-11-12", operatorName: "SNCB",
    product: "IC 531", headsign: "Gent", fetchedAt: "2026-11-12T10:01:00Z", stops, alertIds: [] };
}

describe("official realtime recovery", () => {
  it("bounds overdue queries without letting them displace upcoming stations", async () => {
    const times = ["06:59", "08:50", "09:00", "09:10", "09:50", "10:10", "10:20", "10:30"];
    const stops = times.map((clock, index) => stop(String(index), index + 1, {
      passed: index < 5, scheduledDeparture: `2026-11-12T${clock}:00Z`, expectedDeparture: `2026-11-12T${clock}:00Z`,
    }));
    const overlay = new IRailPlatformOverlay("https://example.test", async (url) => {
      const station = new URL(String(url)).searchParams.get("station")!;
      const selected = stops.find((value) => value.stationName === station)!;
      return Response.json({ timestamp: "1794477660", departures: { departure: [{
        time: String(Date.parse(selected.scheduledDeparture!) / 1_000), delay: "1200", vehicle: "IC 531", platform: "9",
      }] } });
    });
    const observations = await overlay.platformUpdates(trip(stops));
    expect(observations.map((value) => value.stationId)).toEqual(["3", "4", "5", "6"]);
  });

  it("recovers recent passed stops across midnight but excludes unbounded unknown times", async () => {
    const valid = stop("late", 1, { passed: true, scheduledDeparture: "2026-11-12T23:55:00Z", expectedDeparture: "2026-11-12T23:55:00Z" });
    const unknown = stop("unknown", 2, { passed: true, scheduledDeparture: null, expectedDeparture: null });
    const overlay = new IRailPlatformOverlay("https://example.test", async () => Response.json({
      timestamp: "1794528060", departures: { departure: [{ time: "1794527700", delay: "1200", vehicle: "IC 531", platform: "9" }] },
    }));
    const observations = await overlay.platformUpdates({ ...trip([valid, unknown]), fetchedAt: "2026-11-13T00:01:00Z" });
    expect(observations).toEqual([expect.objectContaining({ stationId: "late", expectedDeparture: "2026-11-13T00:15:00.000Z" })]);
  });

  it("recovers a delayed boarding stop after its base timetable departure has passed", async () => {
    const now = () => new Date("2026-11-12T10:01:00Z");
    const place = (name: string, departure: string) => ({ name, stopId: `be-${name}`, lat: 50.8, lon: 4.3,
      departure, scheduledDeparture: departure, track: "2", scheduledTrack: "2" });
    const provider = new TransitousProvider("https://example.test", async () => Response.json({ legs: [{
      mode: "RAIL", tripId: "test-531", displayName: "IC 531", from: place("Brussels", "2026-11-12T10:00:00Z"),
      to: place("Gent", "2026-11-12T11:00:00Z"),
    }] }), now);
    const overlay = new IRailPlatformOverlay("https://example.test", async () => Response.json({
      timestamp: "1794477660", departures: { departure: [{ time: "1794477600", delay: "1200", vehicle: "IC 531", platform: "9" }] },
    }), now);
    const result = await new ProviderRegistry([provider], new TripSnapshotEnricher([overlay])).fetchTrip(trip([]));
    expect(result.stops[0]).toMatchObject({ passed: false, expectedPlatform: "9", expectedDeparture: "2026-11-12T10:20:00.000Z" });
  });
});

describe("stop identity across changed routes", () => {
  it("does not carry another station's platform into the same sequence", () => {
    const previous = trip([stop("B", 2, { expectedPlatform: "15", platformSource: "iRail", platformObservedAt: "2026-11-12T09:59:00Z" })]);
    const current = trip([stop("X", 2, { expectedPlatform: "3" })]);
    expect(carryForwardPlatforms(previous, current).stops[0]).toMatchObject({ stationId: "X", expectedPlatform: "3", platformSource: "Transitous" });
  });

  it("does not compare delay, platform or cancellation to another station at the same sequence", () => {
    const previous = trip([stop("B", 2)]);
    const current = trip([stop("X", 2, { cancelled: true, expectedPlatform: "9", expectedDeparture: "2026-11-12T10:20:00Z" })]);
    expect(diffSnapshots(previous, current, defaultPushPreferences)).toEqual([]);
    const changedPlatform = trip([stop("X", 2, { expectedPlatform: "9", expectedDeparture: "2026-11-12T10:20:00Z" })]);
    expect(diffSnapshots(previous, changedPlatform, defaultPushPreferences)).toEqual([]);
  });

  it("continues to announce a real change at the same station", () => {
    const events = diffSnapshots(trip([stop("B", 2)]), trip([stop("B", 2, { expectedPlatform: "9" })]), defaultPushPreferences);
    expect(events).toEqual([expect.objectContaining({ kind: "platform-change", stopId: "B", oldValue: "2", newValue: "9" })]);
  });
});
