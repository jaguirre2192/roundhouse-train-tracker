import { transit_realtime } from "gtfs-realtime-bindings";
import { describe, expect, it } from "vitest";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { EnturVehiclePositionOverlay } from "../src/providers/entur-vehicle-position.js";

const id = "VYG:ServiceJourney:1828_481200-R";
const now = new Date("2026-11-13T17:54:00Z");
const trip = (): TripSnapshot => ({
  id: "no-test", source: "transitous", nativeId: `20261113_18:00_no-Entur_${id}`, serviceDate: "2026-11-13",
  operatorName: "Vy", product: "R40", headsign: "Bergen", fetchedAt: now.toISOString(), alertIds: [],
  stops: [{ stationId: "no-bergen", stationName: "Bergen", countryCode: "NO", latitude: 60.39, longitude: 5.33,
    sequence: 1, scheduledArrival: null, scheduledDeparture: now.toISOString(), expectedArrival: null,
    expectedDeparture: now.toISOString(), plannedPlatform: null, expectedPlatform: null, platformSource: null,
    platformObservedAt: null, cancelled: false, passed: false }],
});
function vehicle(): transit_realtime.IVehiclePosition {
  return { trip: { tripId: id, startDate: "20261113" }, position: { latitude: 60.43, longitude: 5.62 }, timestamp: now.getTime() / 1000 - 10 };
}
function provider(values: transit_realtime.IVehiclePosition[]) {
  let requests = 0;
  const overlay = new EnturVehiclePositionOverlay("https://example.test/positions", async () => {
    requests += 1;
    const bytes = transit_realtime.FeedMessage.encode({ header: { gtfsRealtimeVersion: "2.0" },
      entity: values.map((value, index) => ({ id: String(index), vehicle: value })) }).finish();
    return new Response(Uint8Array.from(bytes).buffer);
  }, () => now);
  return { overlay, count: () => requests };
}

describe("Entur vehicle positions", () => {
  it("joins exact journey and service date with vehicle-reported timestamp, sharing in-flight work", async () => {
    const { overlay, count } = provider([vehicle()]);
    const [first, second] = await Promise.all([overlay.positionUpdates(trip()), overlay.positionUpdates(trip())]);
    expect(first).toEqual(second);
    expect(first[0]).toMatchObject({ source: "real", asOf: "2026-11-13T17:53:50.000Z", heading: null });
    expect(first[0]?.latitude).toBeCloseTo(60.43);
    expect(count()).toBe(1);
  });

  it.each(["wrong journey", "wrong date", "missing date", "missing timestamp", "stale", "future", "invalid coordinates", "duplicates"])("rejects %s", async (kind) => {
    const value = vehicle();
    if (kind === "wrong journey") value.trip!.tripId = "VYG:ServiceJourney:other-R";
    if (kind === "wrong date") value.trip!.startDate = "20261112";
    if (kind === "missing date") delete value.trip!.startDate;
    if (kind === "missing timestamp") delete value.timestamp;
    if (kind === "stale") value.timestamp = now.getTime() / 1000 - 301;
    if (kind === "future") value.timestamp = now.getTime() / 1000 + 121;
    if (kind === "invalid coordinates") value.position!.latitude = 91;
    expect(await provider(kind === "duplicates" ? [value, value] : [value]).overlay.positionUpdates(trip())).toEqual([]);
  });

  it.each(["replacement bus", "wrong embedded date", "generic line identity"])("does not fetch for %s", async (kind) => {
    const snapshot = trip();
    if (kind === "replacement bus") snapshot.nativeId = "20261113_18:00_no-Entur_VYG:ServiceJourney:BUS-825_761674-R";
    if (kind === "wrong embedded date") snapshot.nativeId = `20261112_18:00_no-Entur_${id}`;
    if (kind === "generic line identity") snapshot.nativeId = "no-Entur_R40";
    const { overlay, count } = provider([vehicle()]);
    expect(await overlay.positionUpdates(snapshot)).toEqual([]);
    expect(count()).toBe(0);
  });
});
