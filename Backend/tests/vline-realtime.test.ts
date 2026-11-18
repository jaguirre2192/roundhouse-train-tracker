import { transit_realtime } from "gtfs-realtime-bindings";
import { describe, expect, it } from "vitest";
import { diffSnapshots } from "../src/domain/events.js";
import { defaultPushPreferences, type TripSnapshot } from "../src/domain/snapshot.js";
import { TripSnapshotEnricher } from "../src/providers/platform-overlay.js";
import { VLineRealtimeOverlay } from "../src/providers/vline-realtime.js";

const now = new Date("2026-07-21T20:30:00.000Z");
const feedTime = Math.floor(Date.parse("2026-07-21T20:29:45.000Z") / 1_000);
const nativeTripId = "01-SER--5-T0-8339";

function trip(): TripSnapshot {
  return {
    id: `eu:transitous:20260721_21:43_au-vic-Transport-Victoria-regional-trains_${nativeTripId}`,
    source: "transitous",
    nativeId: `20260721_21:43_au-vic-Transport-Victoria-regional-trains_${nativeTripId}`,
    serviceDate: "2026-07-21",
    operatorName: "V/Line",
    product: "Shepparton",
    headsign: "Shepparton",
    fetchedAt: now.toISOString(),
    alertIds: [],
    stops: [
      {
        stationId: "eu:transitous:au-vic-Transport-Victoria-regional-trains_20043",
        stationName: "Southern Cross",
        countryCode: "AU",
        latitude: -37.818,
        longitude: 144.953,
        sequence: 0,
        scheduledArrival: null,
        scheduledDeparture: "2026-07-21T20:43:00.000Z",
        expectedArrival: null,
        expectedDeparture: "2026-07-21T20:43:00.000Z",
        plannedPlatform: null,
        expectedPlatform: null,
        platformSource: null,
        platformObservedAt: null,
        cancelled: false,
        passed: false,
      },
      {
        stationId: "eu:transitous:au-vic-Transport-Victoria-regional-trains_vic:rail:BGH",
        stationName: "Broadmeadows",
        countryCode: "AU",
        latitude: -37.684,
        longitude: 144.919,
        sequence: 1,
        scheduledArrival: "2026-07-21T21:05:00.000Z",
        scheduledDeparture: "2026-07-21T21:06:00.000Z",
        expectedArrival: "2026-07-21T21:05:00.000Z",
        expectedDeparture: "2026-07-21T21:06:00.000Z",
        plannedPlatform: null,
        expectedPlatform: null,
        platformSource: null,
        platformObservedAt: null,
        cancelled: false,
        passed: false,
      },
    ],
  };
}

function tripFeed(relationship = transit_realtime.TripDescriptor.ScheduleRelationship.SCHEDULED): Uint8Array {
  return transit_realtime.FeedMessage.encode({
    header: { gtfsRealtimeVersion: "2.0", timestamp: feedTime },
    entity: [{
      id: "vline-trip",
      tripUpdate: {
        timestamp: feedTime,
        trip: { tripId: nativeTripId, startDate: "20260721", scheduleRelationship: relationship },
        stopTimeUpdate: relationship === transit_realtime.TripDescriptor.ScheduleRelationship.CANCELED ? [] : [
          { stopId: "20043", stopSequence: 1, departure: { delay: 0 } },
          { stopId: "22253", stopSequence: 2, arrival: { delay: 420 }, departure: { delay: 420 } },
        ],
      },
    }],
  }).finish();
}

function vehicleFeed(): Uint8Array {
  return transit_realtime.FeedMessage.encode({
    header: { gtfsRealtimeVersion: "2.0", timestamp: feedTime },
    entity: [{
      id: "vline-vehicle",
      vehicle: {
        trip: { tripId: nativeTripId, startDate: "20260721" },
        position: { latitude: -37.7, longitude: 144.94, bearing: 18 },
        timestamp: feedTime,
      },
    }],
  }).finish();
}

function response(value: Uint8Array): Response {
  const bytes = new Uint8Array(value.byteLength);
  bytes.set(value);
  return new Response(bytes.buffer, { status: 200 });
}

describe("VLineRealtimeOverlay", () => {
  it("maps official expected times and produces a delay notification without inventing a platform", async () => {
    const requestedHeaders: Headers[] = [];
    const overlay = new VLineRealtimeOverlay(
      "fixture-key",
      "https://vline.test/trip-updates",
      "https://vline.test/vehicle-positions",
      async (_input, init) => {
        requestedHeaders.push(new Headers(init?.headers));
        return response(tripFeed());
      },
      () => now,
    );

    const previous = trip();
    const current = await new TripSnapshotEnricher([overlay]).enrich(previous);
    const events = diffSnapshots(previous, current, defaultPushPreferences);

    expect(current.stops[1]).toMatchObject({
      expectedArrival: "2026-07-21T21:12:00.000Z",
      expectedDeparture: "2026-07-21T21:13:00.000Z",
      plannedPlatform: null,
      expectedPlatform: null,
    });
    expect(events).toContainEqual(expect.objectContaining({ kind: "delay-threshold", newValue: "7" }));
    expect(events.some((event) => event.kind === "platform-change")).toBe(false);
    expect(requestedHeaders[0]!.get("KeyId")).toBe("fixture-key");
  });

  it("maps a whole-trip cancellation into cancellation events", async () => {
    const overlay = new VLineRealtimeOverlay(
      "fixture-key",
      "https://vline.test/cancelled",
      "https://vline.test/vehicle-positions",
      async () => response(tripFeed(transit_realtime.TripDescriptor.ScheduleRelationship.CANCELED)),
      () => now,
    );
    const previous = trip();
    const current = await new TripSnapshotEnricher([overlay]).enrich(previous);

    expect(current.stops.every((stop) => stop.cancelled)).toBe(true);
    expect(diffSnapshots(previous, current, defaultPushPreferences))
      .toEqual(expect.arrayContaining([expect.objectContaining({ kind: "cancellation" })]));
  });

  it("maps an official fresh vehicle position", async () => {
    const overlay = new VLineRealtimeOverlay(
      "fixture-key",
      "https://vline.test/trip-updates",
      "https://vline.test/vehicle-positions",
      async () => response(vehicleFeed()),
      () => now,
    );

    const positions = await overlay.positionUpdates(trip());
    expect(positions).toHaveLength(1);
    expect(positions[0]!.latitude).toBeCloseTo(-37.7, 5);
    expect(positions[0]!.longitude).toBeCloseTo(144.94, 5);
    expect(positions[0]).toMatchObject({
      heading: 18,
      source: "real",
      confidence: 1,
      asOf: "2026-07-21T20:29:45.000Z",
      provider: "Transport Victoria V/Line GTFS-RT",
    });
  });

  it("rejects stale official feeds", async () => {
    const overlay = new VLineRealtimeOverlay(
      "fixture-key",
      "https://vline.test/stale",
      "https://vline.test/vehicle-positions",
      async () => response(transit_realtime.FeedMessage.encode({
        header: { gtfsRealtimeVersion: "2.0", timestamp: feedTime - 600 },
        entity: [],
      }).finish()),
      () => now,
    );

    await expect(overlay.platformUpdates(trip())).rejects.toThrow("stale or in the future");
  });
});
