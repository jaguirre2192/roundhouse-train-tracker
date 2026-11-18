import { transit_realtime } from "gtfs-realtime-bindings";
import { describe, expect, it } from "vitest";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { TripSnapshotEnricher } from "../src/providers/platform-overlay.js";
import { ViaRailVehiclePositionOverlay } from "../src/providers/via-rail-vehicle-position.js";

function response(startDate = "20260721", timestamp = 1_784_662_604,
  edit: (payload: transit_realtime.IFeedMessage) => void = () => {}): Response {
  const payload: transit_realtime.IFeedMessage = {
    header: { gtfsRealtimeVersion: "2.0", timestamp },
    entity: [{
      id: "via-557",
      vehicle: {
        trip: { tripId: "557", startDate, routeId: "226-576" },
        position: { latitude: 45.5017, longitude: -73.5673, bearing: 271, speed: 18 },
        timestamp,
      },
    }],
  };
  edit(payload);
  const value = transit_realtime.FeedMessage.encode(payload).finish();
  const copy = new Uint8Array(value.byteLength);
  copy.set(value);
  return new Response(copy.buffer, { status: 200 });
}

function snapshot(): TripSnapshot {
  return {
    id: "eu:transitous:20260721_06:20_ca-Viarail_557",
    source: "transitous",
    nativeId: "20260721_06:20_ca-Viarail_557",
    serviceDate: "2026-07-21",
    operatorName: "VIA Rail",
    product: "VIA Rail",
    headsign: "Ottawa",
    fetchedAt: "2026-07-21T19:37:00.000Z",
    alertIds: [],
    stops: [{
      stationId: "eu:transitous:ca-Viarail_226",
      stationName: "Montréal",
      countryCode: "CA",
      latitude: 45.5,
      longitude: -73.57,
      sequence: 1,
      scheduledArrival: null,
      scheduledDeparture: "2026-07-21T19:40:00.000Z",
      expectedArrival: null,
      expectedDeparture: "2026-07-21T19:40:00.000Z",
      plannedPlatform: null,
      expectedPlatform: null,
      platformSource: null,
      platformObservedAt: null,
      cancelled: false,
      passed: false,
    }],
  };
}

describe("ViaRailVehiclePositionOverlay", () => {
  it.each(["missing-date", "missing-point-time", "future-point", "missing-coordinate", "zero-point", "deleted", "duplicate"])(
    "withholds %s instead of promoting a fresh feed container or recurring train ID", async (kind) => {
      const overlay = new ViaRailVehiclePositionOverlay("https://via.test/feed", async () => response(undefined, undefined, (payload) => {
        const entity = payload.entity![0]!, vehicle = entity.vehicle!;
        if (kind === "missing-date") delete vehicle.trip!.startDate;
        if (kind === "missing-point-time") delete vehicle.timestamp;
        if (kind === "future-point") vehicle.timestamp = 1_784_662_800;
        if (kind === "missing-coordinate") Reflect.deleteProperty(vehicle.position!, "latitude");
        if (kind === "zero-point") vehicle.position = { latitude: 0, longitude: 0 };
        if (kind === "deleted") entity.isDeleted = true;
        if (kind === "duplicate") payload.entity!.push({ ...entity, id: "duplicate" });
      }), () => new Date("2026-07-21T19:37:45Z"));
      expect(await overlay.positionUpdates(snapshot())).toEqual([]);
    });

  it("retains a five-minute explicit point but rejects it immediately after that bound", async () => {
    let now = new Date((1_784_662_604 + 300) * 1_000);
    const overlay = new ViaRailVehiclePositionOverlay("https://via.test/feed", async () => response(), () => now);
    expect(await overlay.positionUpdates(snapshot())).toEqual([expect.objectContaining({ confidence: 0.8,
      asOf: new Date(1_784_662_604_000).toISOString() })]);
    now = new Date(now.getTime() + 1);
    expect(await overlay.positionUpdates(snapshot())).toEqual([]);
  });

  it("does not invent a north bearing when the protobuf field is absent", async () => {
    const overlay = new ViaRailVehiclePositionOverlay("https://via.test/feed", async () => response(undefined, undefined,
      (value) => { Reflect.deleteProperty(value.entity![0]!.vehicle!.position!, "bearing"); }),
    () => new Date("2026-07-21T19:37:45Z"));
    expect(await overlay.positionUpdates(snapshot())).toEqual([expect.objectContaining({ heading: null })]);
  });

  it("coalesces requests and bounds failure retries without renewing point freshness", async () => {
    let requests = 0, now = new Date("2026-07-21T19:37:45Z");
    const overlay = new ViaRailVehiclePositionOverlay("https://via.test/feed", async () => {
      requests++; return requests === 1 ? new Response("unavailable", { status: 503 }) : response();
    }, () => now);
    await expect(Promise.all([overlay.positionUpdates(snapshot()), overlay.positionUpdates(snapshot())]))
      .rejects.toThrow("returned 503");
    await expect(overlay.positionUpdates(snapshot())).rejects.toThrow("returned 503");
    expect(requests).toBe(1);
    now = new Date(now.getTime() + 30_001);
    const values = await Promise.all([overlay.positionUpdates(snapshot()), overlay.positionUpdates(snapshot())]);
    expect(requests).toBe(2);
    expect(values[0]).toEqual([expect.objectContaining({ asOf: new Date(1_784_662_604_000).toISOString() })]);
  });

  it("joins a fresh public VIA vehicle position by trip and service date", async () => {
    let requestedUrl = "";
    const overlay = new ViaRailVehiclePositionOverlay(
      "https://example.test/via.pb",
      async (input) => {
        requestedUrl = String(input);
        return response();
      },
      () => new Date("2026-07-21T19:37:45.000Z"),
    );

    const value = await new TripSnapshotEnricher([], [overlay]).enrich(snapshot());

    expect(requestedUrl).toBe("https://example.test/via.pb");
    expect(value.positions).toEqual([expect.objectContaining({
      latitude: 45.50170135498047,
      longitude: -73.56729888916016,
      heading: 271,
      source: "real",
      confidence: 1,
      provider: "Catenary VIA Rail GTFS-RT",
    })]);
  });

  it("rejects a mismatched service date", async () => {
    const overlay = new ViaRailVehiclePositionOverlay(
      "https://example.test/via.pb",
      async () => response("20260722"),
      () => new Date("2026-07-21T19:37:45.000Z"),
    );

    expect(await overlay.positionUpdates(snapshot())).toEqual([]);
  });

  it("rejects stale positions", async () => {
    const overlay = new ViaRailVehiclePositionOverlay(
      "https://example.test/via.pb",
      async () => response(),
      () => new Date("2026-07-21T20:00:00.000Z"),
    );

    expect(await overlay.positionUpdates(snapshot())).toEqual([]);
  });
});
