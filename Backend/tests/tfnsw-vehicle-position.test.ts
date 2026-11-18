import { transit_realtime } from "gtfs-realtime-bindings";
import { describe, expect, it, vi } from "vitest";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { TfNSWVehiclePositionOverlay } from "../src/providers/tfnsw-vehicle-position.js";

// Exact identifiers and coordinates observed in the official feed on Nov 13.
const now = new Date("2026-11-13T17:48:47.000Z");
const seconds = now.getTime() / 1_000;
const tripId = "ST21.091126.31.X.7.2042";

function snapshot(): TripSnapshot {
  return {
    id: "test",
    source: "transitous",
    nativeId: `20261113_20:42_au-nsw-Transport-for-New-South-Wales-nsw-trains_${tripId}`,
    serviceDate: "2026-11-13",
    operatorName: "NSW TrainLink",
    product: "ST21",
    headsign: "Melbourne",
    fetchedAt: now.toISOString(),
    stops: [],
    alertIds: [],
  };
}

function vehicle(): transit_realtime.IVehiclePosition {
  return {
    trip: { tripId, startDate: "20261113", startTime: "20:42:00", routeId: "4T.T.ST21" },
    position: { latitude: -35.10631561279297, longitude: 147.36721801757812, bearing: 225 },
    timestamp: seconds - 29,
  };
}

function overlay(vehicles: transit_realtime.IVehiclePosition[], headerTime = seconds) {
  let calls = 0;
  const instance = new TfNSWVehiclePositionOverlay("test-key", "https://example.test/nsw.pb", async (_url, init) => {
    calls += 1;
    expect(new Headers(init?.headers).get("authorization")).toBe("apikey test-key");
    const bytes = transit_realtime.FeedMessage.encode({
      header: { gtfsRealtimeVersion: "1.0", timestamp: headerTime },
      entity: vehicles.map((value, index) => ({ id: String(index), vehicle: value })),
    }).finish();
    return new Response(new Uint8Array(bytes).buffer);
  }, () => now);
  return { instance, calls: () => calls };
}

describe("TfNSWVehiclePositionOverlay", () => {
  it("joins an official railway position by exact trip and originating service day, including overnight", async () => {
    const { instance, calls } = overlay([vehicle()]);
    const positions = await instance.positionUpdates(snapshot());
    expect(positions).toEqual([expect.objectContaining({
      latitude: -35.10631561279297,
      longitude: 147.36721801757812,
      source: "real", confidence: 1,
      asOf: new Date((seconds - 29) * 1_000).toISOString(),
      provider: "Transport for NSW GTFS-RT",
    })]);
    await instance.positionUpdates(snapshot());
    expect(calls()).toBe(1);
  });

  it.each([
    ["another train", (v: transit_realtime.IVehiclePosition) => { v.trip!.tripId = "ST22.091126.31.X.7.2042"; }],
    ["same train on another day", (v: transit_realtime.IVehiclePosition) => { v.trip!.startDate = "20261114"; }],
    ["missing service day", (v: transit_realtime.IVehiclePosition) => { delete v.trip!.startDate; }],
    ["another departure time", (v: transit_realtime.IVehiclePosition) => { v.trip!.startTime = "20:43:00"; }],
    ["coach route", (v: transit_realtime.IVehiclePosition) => { v.trip!.routeId = "4T.C.ST21"; }],
    ["missing route", (v: transit_realtime.IVehiclePosition) => { delete v.trip!.routeId; }],
    ["cancelled train", (v: transit_realtime.IVehiclePosition) => { v.trip!.scheduleRelationship = 3; }],
    ["stale observation", (v: transit_realtime.IVehiclePosition) => { v.timestamp = seconds - 301; }],
    ["future observation", (v: transit_realtime.IVehiclePosition) => { v.timestamp = seconds + 121; }],
    ["undated observation", (v: transit_realtime.IVehiclePosition) => { delete v.timestamp; }],
    ["invalid latitude", (v: transit_realtime.IVehiclePosition) => { v.position!.latitude = 91; }],
    ["invalid longitude", (v: transit_realtime.IVehiclePosition) => { v.position!.longitude = -181; }],
    ["null island", (v: transit_realtime.IVehiclePosition) => { v.position = { latitude: 0, longitude: 0 }; }],
  ] as const)("rejects %s", async (_name, change) => {
    const value = vehicle();
    change(value);
    expect(await overlay([value]).instance.positionUpdates(snapshot())).toEqual([]);
  });

  it("rejects duplicate exact matches", async () => {
    expect(await overlay([vehicle(), vehicle()]).instance.positionUpdates(snapshot())).toEqual([]);
  });

  it.each(["latitude", "longitude"])("rejects an inherited protobuf default for absent %s", async (coordinate) => {
    const feed = transit_realtime.FeedMessage.decode(transit_realtime.FeedMessage.encode({
      header: { gtfsRealtimeVersion: "1.0", timestamp: seconds },
      entity: [{ id: "1", vehicle: vehicle() }],
    }).finish());
    const position = feed.entity[0]!.vehicle!.position!;
    Reflect.deleteProperty(position, coordinate);
    expect(Reflect.get(position, coordinate)).toBe(0);
    const decoded = vi.spyOn(transit_realtime.FeedMessage, "decode").mockReturnValueOnce(feed);
    try {
      expect(await overlay([vehicle()]).instance.positionUpdates(snapshot())).toEqual([]);
    } finally {
      decoded.mockRestore();
    }
  });

  it("does not invent north as the heading when the protobuf field is absent", async () => {
    const value = vehicle();
    delete value.position!.bearing;
    expect((await overlay([value]).instance.positionUpdates(snapshot()))[0]?.heading).toBeNull();
  });

  it("matches MOTIS previous-day 27:55 to NSW calendar-day 03:55 without changing the trip ID", async () => {
    const value = snapshot();
    value.nativeId = value.nativeId.replace("20:42", "27:55");
    const reported = vehicle();
    reported.trip!.startDate = "20261114";
    reported.trip!.startTime = "03:55:00";
    expect(await overlay([reported]).instance.positionUpdates(value)).toHaveLength(1);
    reported.trip!.startDate = "20261113";
    expect(await overlay([reported]).instance.positionUpdates(value)).toEqual([]);
  });

  it("does not request positions for another feed", async () => {
    const value = snapshot();
    value.nativeId = value.nativeId.replace("nsw-trains", "sydneytrains");
    const { instance, calls } = overlay([vehicle()]);
    expect(await instance.positionUpdates(value)).toEqual([]);
    expect(calls()).toBe(0);
  });

  it("rejects stale feed headers even with a recent vehicle timestamp", async () => {
    await expect(overlay([vehicle()], seconds - 301).instance.positionUpdates(snapshot())).rejects.toThrow("stale or undated");
  });

  it("retries immediately after a rejected feed request", async () => {
    let calls = 0;
    const instance = new TfNSWVehiclePositionOverlay("test-key", "https://example.test/retry.pb", async () => {
      calls += 1;
      if (calls === 1) return new Response(null, { status: 503 });
      const bytes = transit_realtime.FeedMessage.encode({
        header: { gtfsRealtimeVersion: "1.0", timestamp: seconds },
        entity: [{ id: "1", vehicle: vehicle() }],
      }).finish();
      return new Response(new Uint8Array(bytes).buffer);
    }, () => now);
    await expect(instance.positionUpdates(snapshot())).rejects.toThrow("503");
    expect(await instance.positionUpdates(snapshot())).toHaveLength(1);
    expect(calls).toBe(2);
  });

  it("does not retain the cache across a clock rollback", async () => {
    let calls = 0;
    let clock = now;
    const instance = new TfNSWVehiclePositionOverlay("test-key", "https://example.test/clock.pb", async () => {
      calls += 1;
      const bytes = transit_realtime.FeedMessage.encode({
        header: { gtfsRealtimeVersion: "1.0", timestamp: seconds },
        entity: [{ id: "1", vehicle: vehicle() }],
      }).finish();
      return new Response(new Uint8Array(bytes).buffer);
    }, () => clock);
    expect(await instance.positionUpdates(snapshot())).toHaveLength(1);
    clock = new Date(now.getTime() - 10_000);
    expect(await instance.positionUpdates(snapshot())).toHaveLength(1);
    expect(calls).toBe(2);
  });

  it("does not evict a newer successful cache when an older request fails", async () => {
    let calls = 0;
    let clock = now;
    let rejectFirst!: (error: Error) => void;
    const instance = new TfNSWVehiclePositionOverlay("test-key", "https://example.test/race.pb", async () => {
      calls += 1;
      if (calls === 1) return new Promise<Response>((_resolve, reject) => { rejectFirst = reject; });
      const bytes = transit_realtime.FeedMessage.encode({
        header: { gtfsRealtimeVersion: "1.0", timestamp: seconds },
        entity: [{ id: "1", vehicle: vehicle() }],
      }).finish();
      return new Response(new Uint8Array(bytes).buffer);
    }, () => clock);
    const rejected = expect(instance.positionUpdates(snapshot())).rejects.toThrow("older request failed");
    clock = new Date(now.getTime() + 31_000);
    expect(await instance.positionUpdates(snapshot())).toHaveLength(1);
    rejectFirst(new Error("older request failed"));
    await rejected;
    expect(await instance.positionUpdates(snapshot())).toHaveLength(1);
    expect(calls).toBe(2);
  });
});
