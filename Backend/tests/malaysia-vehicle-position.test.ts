import { transit_realtime } from "gtfs-realtime-bindings";
import { describe, expect, it, vi } from "vitest";
import { MalaysiaVehiclePositionOverlay } from "../src/providers/malaysia-vehicle-position.js";
import { TripSnapshotEnricher } from "../src/providers/platform-overlay.js";
import { response, snapshot } from "./helpers/malaysia-vehicle-position.js";


describe("MalaysiaVehiclePositionOverlay", () => {
  it("joins the official KTMB vehicle feed to a Transitous trip", async () => {
    let requestHeaders: HeadersInit | undefined;
    const overlay = new MalaysiaVehiclePositionOverlay(
      "https://example.test/ktmb.pb",
      async (_input, init) => {
        requestHeaders = init?.headers;
        return response();
      },
      () => new Date("2026-07-21T12:55:30.000Z"),
    );

    const value = await new TripSnapshotEnricher([], [overlay]).enrich(snapshot());

    expect(value.positions).toEqual([expect.objectContaining({
      latitude: 3.113956928253174,
      longitude: 101.67303466796875,
      heading: 185,
      source: "real",
      confidence: 1,
      provider: "Malaysia Open API KTMB GTFS-RT",
    })]);
    expect(new Headers(requestHeaders).has("accept")).toBe(false);
  });

  it("rejects stale positions", async () => {
    const overlay = new MalaysiaVehiclePositionOverlay(
      "https://example.test/ktmb.pb",
      async () => response(),
      () => new Date("2026-07-21T13:10:00.000Z"),
    );

    const value = await overlay.positionUpdates(snapshot());

    expect(value).toEqual([]);
  });

  it("retains an otherwise valid three-minute-old position with its original timestamp", async () => {
    const observedAt = Date.parse("2026-07-21T12:52:30Z");
    const overlay = new MalaysiaVehiclePositionOverlay("https://example.test/three-minute.pb",
      async () => response(vehicle => { vehicle.timestamp = observedAt / 1_000; }),
      () => new Date("2026-07-21T12:55:30Z"));
    expect(await overlay.positionUpdates(snapshot())).toEqual([expect.objectContaining({
      source: "real", confidence: 0.8, asOf: "2026-07-21T12:52:30.000Z",
    })]);
  });

  it.each([300_001, 360_000, 899_000])("withholds a point aged %i ms rather than emitting old GPS", async (age) => {
    const now = Date.parse("2026-07-21T12:55:30Z");
    const overlay = new MalaysiaVehiclePositionOverlay("https://example.test/old-gps.pb",
      async () => response(vehicle => { vehicle.timestamp = (now - age) / 1_000; }), () => new Date(now));
    expect(await overlay.positionUpdates(snapshot())).toEqual([]);
  });

  it.each([
    ["another service date", (v: transit_realtime.IVehiclePosition) => { v.trip!.startDate = "20260720"; }],
    ["conflicting dated prefix", (v: transit_realtime.IVehiclePosition) => {
      v.trip!.tripId = "20260720_2178"; v.trip!.startDate = "20260721";
    }],
    ["another exact trip", (v: transit_realtime.IVehiclePosition) => { v.trip!.tripId = "weekday_3178"; }],
    ["future position", (v: transit_realtime.IVehiclePosition) => { v.timestamp = 1_784_639_000; }],
    ["undated position", (v: transit_realtime.IVehiclePosition) => { delete v.timestamp; }],
    ["out-of-range latitude", (v: transit_realtime.IVehiclePosition) => { v.position!.latitude = 91; }],
    ["out-of-range longitude", (v: transit_realtime.IVehiclePosition) => { v.position!.longitude = 181; }],
    ["null island", (v: transit_realtime.IVehiclePosition) => { v.position = { latitude: 0, longitude: 0 }; }],
  ] as const)("rejects %s", async (_name, change) => {
    const overlay = new MalaysiaVehiclePositionOverlay("https://example.test/ktmb.pb", async () => response(change),
      () => new Date("2026-07-21T12:55:30.000Z"));
    expect(await overlay.positionUpdates(snapshot())).toEqual([]);
  });

  it("rejects an explicitly deleted vehicle entity", async () => {
    const feed = transit_realtime.FeedMessage.decode(new Uint8Array(await response().arrayBuffer()));
    feed.entity[0]!.isDeleted = true;
    const bytes = transit_realtime.FeedMessage.encode(feed).finish();
    const overlay = new MalaysiaVehiclePositionOverlay("https://example.test/deleted.pb",
      async () => new Response(new Uint8Array(bytes).buffer), () => new Date("2026-07-21T12:55:30Z"));
    expect(await overlay.positionUpdates(snapshot())).toEqual([]);
  });

  it("does not use a product train number when the exact trip ID differs", async () => {
    const value = snapshot();
    value.nativeId = value.nativeId.replace(/_2178$/u, "_3178");
    const overlay = new MalaysiaVehiclePositionOverlay("https://example.test/ktmb.pb", async () => response(),
      () => new Date("2026-07-21T12:55:30.000Z"));
    expect(await overlay.positionUpdates(value)).toEqual([]);
  });

  it("does not attach today's undated position to tomorrow's repeated service", async () => {
    const value = snapshot();
    value.serviceDate = "2026-07-22";
    const overlay = new MalaysiaVehiclePositionOverlay("https://example.test/ktmb.pb", async () => response(),
      () => new Date("2026-07-21T12:55:30.000Z"));
    expect(await overlay.positionUpdates(value)).toEqual([]);
  });

  it("does not fetch another operator that shares the train number", async () => {
    const value = snapshot();
    value.nativeId = value.nativeId.replace("my-ktmb", "my-other");
    let fetched = false;
    const overlay = new MalaysiaVehiclePositionOverlay("https://example.test/ktmb.pb", async () => {
      fetched = true; return response();
    });
    expect(await overlay.positionUpdates(value)).toEqual([]);
    expect(fetched).toBe(false);
  });

  it("does not turn an omitted heading into north", async () => {
    const overlay = new MalaysiaVehiclePositionOverlay("https://example.test/ktmb.pb", async () => response((v) => {
      delete v.position!.bearing;
    }), () => new Date("2026-07-21T12:55:30.000Z"));
    expect((await overlay.positionUpdates(snapshot()))[0]?.heading).toBeNull();
  });

  it.each(["latitude", "longitude"])("rejects an inherited protobuf default for absent %s", async (coordinate) => {
    const feed = transit_realtime.FeedMessage.decode(new Uint8Array(await response().arrayBuffer()));
    const position = feed.entity[0]!.vehicle!.position!;
    Reflect.deleteProperty(position, coordinate);
    expect(Reflect.get(position, coordinate)).toBe(0);
    const decoded = vi.spyOn(transit_realtime.FeedMessage, "decode").mockReturnValueOnce(feed);
    const overlay = new MalaysiaVehiclePositionOverlay("https://example.test/absent-coordinate.pb", async () => response(),
      () => new Date("2026-07-21T12:55:30Z"));
    try {
      expect(await overlay.positionUpdates(snapshot())).toEqual([]);
    } finally {
      decoded.mockRestore();
    }
  });

  it("coalesces concurrent official-feed requests across overlay instances", async () => {
    let calls = 0;
    let finish!: (value: Response) => void;
    const fetcher: typeof fetch = async () => {
      calls += 1;
      return new Promise<Response>((resolve) => { finish = resolve; });
    };
    const now = () => new Date("2026-07-21T12:55:30Z");
    const first = new MalaysiaVehiclePositionOverlay(undefined, fetcher, now);
    const second = new MalaysiaVehiclePositionOverlay(undefined, fetcher, now);
    const requests = [first, second, first, second].map((overlay) => overlay.positionUpdates(snapshot()));
    await vi.waitFor(() => expect(calls).toBe(1));
    finish(response());
    expect((await Promise.all(requests)).every((positions) => positions.length === 1)).toBe(true);
    expect(await second.positionUpdates(snapshot())).toHaveLength(1);
    expect(calls).toBe(1);
  });

  it("limits polling to one request per 30 seconds, including failed requests", async () => {
    let calls = 0;
    let clock = new Date("2026-07-21T12:55:30Z");
    const overlay = new MalaysiaVehiclePositionOverlay("https://example.test/quota.pb", async () => {
      calls += 1;
      return calls === 1 ? new Response(null, { status: 503 }) : response();
    }, () => clock);
    const attempts = await Promise.allSettled(Array.from({ length: 10 }, () => overlay.positionUpdates(snapshot())));
    expect(attempts.every((result) => result.status === "rejected")).toBe(true);
    expect(calls).toBe(1);
    clock = new Date(clock.getTime() + 29_999);
    await expect(overlay.positionUpdates(snapshot())).rejects.toThrow("503");
    expect(calls).toBe(1);
    clock = new Date(clock.getTime() + 1);
    expect(await overlay.positionUpdates(snapshot())).toHaveLength(1);
    clock = new Date(clock.getTime() + 29_999);
    expect(await overlay.positionUpdates(snapshot())).toHaveLength(1);
    expect(calls).toBe(2);
  });

  it.each(["60", "Tue, 21 Jul 2026 12:56:30 GMT"])("honors Retry-After %s", async (retryAfter) => {
    let calls = 0;
    let clock = new Date("2026-07-21T12:55:30Z");
    const overlay = new MalaysiaVehiclePositionOverlay("https://example.test/retry-after.pb", async () => {
      calls += 1;
      return calls === 1 ? new Response(null, { status: 429, headers: { "retry-after": retryAfter } }) : response();
    }, () => clock);
    await expect(overlay.positionUpdates(snapshot())).rejects.toThrow("429");
    clock = new Date(clock.getTime() + 30_000);
    await expect(overlay.positionUpdates(snapshot())).rejects.toThrow("429");
    expect(calls).toBe(1);
    clock = new Date(clock.getTime() + 30_000);
    expect(await overlay.positionUpdates(snapshot())).toHaveLength(1);
    expect(calls).toBe(2);
  });

  it("rebases the cooldown after clock rollback without a new request burst", async () => {
    let calls = 0;
    let clock = new Date("2026-07-21T12:55:30Z");
    const overlay = new MalaysiaVehiclePositionOverlay("https://example.test/rollback.pb", async () => {
      calls += 1; return response();
    }, () => clock);
    expect(await overlay.positionUpdates(snapshot())).toHaveLength(1);
    clock = new Date(clock.getTime() - 10_000);
    expect(await overlay.positionUpdates(snapshot())).toHaveLength(1);
    expect(calls).toBe(1);
    clock = new Date(clock.getTime() + 30_000);
    expect(await overlay.positionUpdates(snapshot())).toHaveLength(1);
    expect(calls).toBe(2);
  });
});
