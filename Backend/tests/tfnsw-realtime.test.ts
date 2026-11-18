import { transit_realtime } from "gtfs-realtime-bindings";
import { describe, expect, it } from "vitest";
import { diffSnapshots } from "../src/domain/events.js";
import { defaultPushPreferences, type TripSnapshot } from "../src/domain/snapshot.js";
import { TripSnapshotEnricher } from "../src/providers/platform-overlay.js";
import { TfNSWRealtimeOverlay } from "../src/providers/tfnsw-realtime.js";

const nativeTripId = "SP32.200726.31.P.3.0700";

function trip(): TripSnapshot {
  return {
    id: `eu:transitous:20260722_07:00_au-nsw-Transport-for-New-South-Wales-nsw-trains_${nativeTripId}`,
    source: "transitous",
    nativeId: `20260722_07:00_au-nsw-Transport-for-New-South-Wales-nsw-trains_${nativeTripId}`,
    serviceDate: "2026-07-22",
    operatorName: "NSW TrainLink",
    product: "632",
    headsign: "Central",
    fetchedAt: "2026-07-21T20:30:00.000Z",
    alertIds: [],
    stops: [
      {
        stationId: "eu:transitous:au-nsw-Transport-for-New-South-Wales-nsw-trains_26043",
        stationName: "Canberra Station",
        countryCode: "AU",
        latitude: -35.319,
        longitude: 149.149,
        sequence: 0,
        scheduledArrival: null,
        scheduledDeparture: "2026-07-21T21:00:00.000Z",
        expectedArrival: null,
        expectedDeparture: "2026-07-21T21:00:00.000Z",
        plannedPlatform: "1",
        expectedPlatform: "1",
        platformSource: "Transitous",
        platformObservedAt: null,
        cancelled: false,
        passed: false,
      },
      {
        stationId: "eu:transitous:au-nsw-Transport-for-New-South-Wales-nsw-trains_2000325",
        stationName: "Central Station",
        countryCode: "AU",
        latitude: -33.883,
        longitude: 151.206,
        sequence: 1,
        scheduledArrival: "2026-07-22T01:30:00.000Z",
        scheduledDeparture: null,
        expectedArrival: "2026-07-22T01:30:00.000Z",
        expectedDeparture: null,
        plannedPlatform: "5",
        expectedPlatform: "5",
        platformSource: "Transitous",
        platformObservedAt: null,
        cancelled: false,
        passed: false,
      },
    ],
  };
}

function tripFeed(
  relationship = transit_realtime.TripDescriptor.ScheduleRelationship.SCHEDULED,
): Uint8Array {
  return transit_realtime.FeedMessage.encode({
    header: { gtfsRealtimeVersion: "2.0", timestamp: 1_784_638_800 },
    entity: [{
      id: "trip-update",
      tripUpdate: {
        timestamp: 1_784_638_800,
        trip: {
          tripId: nativeTripId,
          startDate: "20260722",
          startTime: "07:00:00",
          routeId: "4T.T.SP32",
          scheduleRelationship: relationship,
        },
        stopTimeUpdate: relationship === transit_realtime.TripDescriptor.ScheduleRelationship.CANCELED ? [] : [
          { stopSequence: 1, stopId: "26043", departure: { delay: 0 } },
          { stopSequence: 11, stopId: "2000326", arrival: { delay: 420 } },
        ],
      },
    }],
  }).finish();
}

function alertFeed(): Uint8Array {
  return transit_realtime.FeedMessage.encode({
    header: { gtfsRealtimeVersion: "2.0", timestamp: 1_784_638_800 },
    entity: [{
      id: "route-disruption",
      alert: {
        activePeriod: [{ start: 1_784_600_000, end: 1_784_700_000 }],
        informedEntity: [{ agencyId: "711", routeId: "4T.T.SP32" }],
        effect: transit_realtime.Alert.Effect.SIGNIFICANT_DELAYS,
      },
    }],
  }).finish();
}

function response(value: Uint8Array): Response {
  const bytes = new Uint8Array(value.byteLength);
  bytes.set(value);
  return new Response(bytes.buffer, { status: 200 });
}

describe("TfNSWRealtimeOverlay", () => {
  it("maps an official platform change, delay, and alert into watcher events", async () => {
    const previous = trip();
    const overlay = new TfNSWRealtimeOverlay(
      "fixture-token",
      "https://tfnsw.test/trips",
      "https://tfnsw.test/alerts",
      async (input) => response(String(input).includes("alerts") ? alertFeed() : tripFeed()),
      () => new Date("2026-07-21T20:30:00.000Z"),
    );

    const current = await new TripSnapshotEnricher([overlay]).enrich(previous);
    const events = diffSnapshots(previous, current, defaultPushPreferences);

    expect(current.stops[1]).toMatchObject({
      expectedArrival: "2026-07-22T01:37:00.000Z",
      plannedPlatform: "5",
      expectedPlatform: "6",
      platformSource: "Transport for NSW GTFS-RT",
    });
    expect(current.alertIds).toEqual(["tfnsw:route-disruption"]);
    expect(events).toEqual(expect.arrayContaining([
      expect.objectContaining({ kind: "platform-change", oldValue: "5", newValue: "6" }),
      expect.objectContaining({ kind: "delay-threshold", newValue: "7" }),
      expect.objectContaining({ kind: "disruption", newValue: "tfnsw:route-disruption" }),
    ]));
  });

  it("maps a whole-trip NSW TrainLink cancellation", async () => {
    const overlay = new TfNSWRealtimeOverlay(
      "fixture-token",
      "https://tfnsw.test/cancelled-trips",
      "https://tfnsw.test/alerts",
      async () => response(tripFeed(transit_realtime.TripDescriptor.ScheduleRelationship.CANCELED)),
    );

    const value = await new TripSnapshotEnricher([overlay]).enrich(trip());

    expect(value.stops.every((stop) => stop.cancelled)).toBe(true);
  });

  it.each(["trip", "alert"])("retries a failed %s feed immediately", async (kind) => {
    let calls = 0;
    const overlay = new TfNSWRealtimeOverlay("fixture-token", "https://tfnsw.test/trips", "https://tfnsw.test/alerts",
      async (input) => {
        const isTarget = String(input).includes("alerts") === (kind === "alert");
        if (isTarget && ++calls === 1) return new Response(null, { status: 503 });
        return response(String(input).includes("alerts") ? alertFeed() : tripFeed());
      }, () => new Date("2026-07-21T20:30:00Z"));
    const load = () => kind === "trip" ? overlay.platformUpdates(trip()) : overlay.tripAlertIds(trip());
    await expect(load()).rejects.toThrow("503");
    expect((await load()).length).toBeGreaterThan(0);
    expect(calls).toBe(2);
  });

  it.each(["trip", "alert"])("keeps a newer %s cache when an older request fails", async (kind) => {
    let calls = 0;
    let clock = new Date("2026-07-21T20:30:00Z");
    let rejectFirst!: (error: Error) => void;
    const overlay = new TfNSWRealtimeOverlay("fixture-token", "https://tfnsw.test/trips", "https://tfnsw.test/alerts",
      async (input) => {
        const isTarget = String(input).includes("alerts") === (kind === "alert");
        if (isTarget && ++calls === 1) return new Promise<Response>((_resolve, reject) => { rejectFirst = reject; });
        return response(String(input).includes("alerts") ? alertFeed() : tripFeed());
      }, () => clock);
    const load = () => kind === "trip" ? overlay.platformUpdates(trip()) : overlay.tripAlertIds(trip());
    // Warm the descriptor before starting the delayed alert request.
    if (kind === "alert") await overlay.platformUpdates(trip());
    const rejected = expect(load()).rejects.toThrow("older request failed");
    await Promise.resolve();
    clock = new Date(clock.getTime() + 61_000);
    expect((await load()).length).toBeGreaterThan(0);
    rejectFirst(new Error("older request failed"));
    await rejected;
    expect((await load()).length).toBeGreaterThan(0);
    expect(calls).toBe(2);
  });

  it.each(["trip", "alert"])("does not reuse a %s cache across clock rollback", async (kind) => {
    let calls = 0;
    let clock = new Date("2026-07-21T20:30:00Z");
    const overlay = new TfNSWRealtimeOverlay("fixture-token", "https://tfnsw.test/trips", "https://tfnsw.test/alerts",
      async (input) => {
        if (String(input).includes("alerts") === (kind === "alert")) calls += 1;
        return response(String(input).includes("alerts") ? alertFeed() : tripFeed());
      }, () => clock);
    const load = () => kind === "trip" ? overlay.platformUpdates(trip()) : overlay.tripAlertIds(trip());
    expect((await load()).length).toBeGreaterThan(0);
    clock = new Date(clock.getTime() - 1_000);
    expect((await load()).length).toBeGreaterThan(0);
    expect(calls).toBe(2);
  });
});
