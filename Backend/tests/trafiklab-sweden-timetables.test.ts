import { describe, expect, it } from "vitest";
import { defaultPushPreferences, type TripSnapshot } from "../src/domain/snapshot.js";
import { diffSnapshots } from "../src/domain/events.js";
import { TripSnapshotEnricher } from "../src/providers/platform-overlay.js";
import { TrafiklabSwedenTimetableOverlay } from "../src/providers/trafiklab-sweden-timetables.js";

function trip(): TripSnapshot {
  return {
    id: "eu:transitous:trafiklab-803",
    source: "transitous",
    nativeId: "20260803_22:05_se-Trafiklab_23000803010096",
    serviceDate: "2026-08-03",
    operatorName: "Öresundståg",
    product: "803",
    headsign: "Østerport",
    fetchedAt: "2026-08-03T20:01:00.000Z",
    alertIds: [],
    stops: [
      {
        stationId: "eu:transitous:se-Trafiklab_740000003",
        stationName: "Malmö Centralstation",
        countryCode: "SE",
        latitude: 55.6088,
        longitude: 13.0002,
        sequence: 1,
        scheduledArrival: null,
        scheduledDeparture: "2026-08-03T20:05:00.000Z",
        expectedArrival: null,
        expectedDeparture: "2026-08-03T20:05:00.000Z",
        plannedPlatform: null,
        expectedPlatform: null,
        platformSource: null,
        platformObservedAt: null,
        cancelled: false,
        passed: false,
      },
      {
        stationId: "eu:transitous:se-Trafiklab_860000858",
        stationName: "CPH Airport",
        countryCode: "DK",
        latitude: 55.6294,
        longitude: 12.6497,
        sequence: 2,
        scheduledArrival: "2026-08-03T20:28:00.000Z",
        scheduledDeparture: null,
        expectedArrival: "2026-08-03T20:28:00.000Z",
        expectedDeparture: null,
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

describe("TrafiklabSwedenTimetableOverlay", () => {
  it.each([false, undefined])("preserves regional evidence when the API realtime flag is %s", async (isRealtime) => {
    const board = {
      scheduled: "2026-08-03T22:05:00", realtime: "2026-08-03T22:05:00", delay: 0, canceled: false,
      route: { name: "Öresundståg", designation: "803", transport_mode: "TRAIN", direction: "Østerport" },
      trip: { trip_id: "known", start_date: "2026-08-03", technical_number: 803 },
      scheduled_platform: { designation: "1" }, realtime_platform: { designation: "1" }, is_realtime: isRealtime,
    };
    const overlay = new TrafiklabSwedenTimetableOverlay("key", "https://example.test", async (input) => {
      if (String(input).includes("/departures/")) return Response.json({ departures: [board] });
      return Response.json({ calls: [{
        stop: { area_id: "740000003" }, scheduledDeparture: board.scheduled, realtimeDeparture: board.realtime,
        departureDelay: 0, departureCanceled: false, scheduled_platform: board.scheduled_platform,
        realtime_platform: board.realtime_platform, is_realtime: isRealtime,
      }] });
    }, () => new Date("2026-08-03T20:02:00Z"));
    expect(await overlay.platformUpdates(trip())).toEqual([{
      stopSequence: 1, stationId: trip().stops[0]!.stationId, plannedPlatform: "1",
      observedAt: "2026-08-03T20:02:00.000Z", source: overlay.sourceName,
    }]);
    const regional = { sourceName: "Regional", supportedCountryCodes: new Set(["SE"]),
      platformUpdates: async () => [{ stopSequence: 1, stationId: trip().stops[0]!.stationId,
        expectedDeparture: "2026-08-03T20:11:00.000Z", expectedPlatform: "9", cancelled: true,
        observedAt: "2026-08-03T20:01:00.000Z", source: "Regional" }] };
    const enriched = await new TripSnapshotEnricher([regional, overlay]).enrich(trip());
    expect(enriched.stops[0]).toMatchObject({ expectedDeparture: "2026-08-03T20:11:00.000Z",
      expectedPlatform: "9", cancelled: true, platformSource: "Regional", platformObservedAt: "2026-08-03T20:01:00.000Z" });
  });

  it("uses explicit on-time trip evidence when the anchor board is scheduled-only", async () => {
    const overlay = new TrafiklabSwedenTimetableOverlay("key", "https://example.test", async (input) => {
      if (String(input).includes("/departures/")) return Response.json({ departures: [{
        scheduled: "2026-08-03T22:05:00", realtime: "2026-08-03T22:05:00", delay: 0, is_realtime: false,
        route: { name: "Öresundståg", designation: "803", transport_mode: "TRAIN", direction: "Østerport" },
        trip: { trip_id: "known", start_date: "2026-08-03", technical_number: 803 },
      }] });
      return Response.json({ calls: [{
        stop: { area_id: "740000003" }, realtimeDeparture: "2026-08-03T22:05:00", departureDelay: 0,
        departureCanceled: false, is_realtime: true,
      }] });
    }, () => new Date("2026-08-03T20:02:00Z"));
    expect(await overlay.platformUpdates(trip())).toEqual([expect.objectContaining({
      expectedDeparture: "2026-08-03T20:05:00.000Z", cancelled: false,
    })]);
  });

  it("tries the upcoming anchor when a recent passed station no longer lists the service", async () => {
    const current = trip();
    current.stops.unshift({ ...current.stops[0]!, stationId: "eu:transitous:se-Trafiklab_740000001", sequence: 0,
      passed: true, scheduledDeparture: "2026-08-03T19:00:00Z", expectedDeparture: "2026-08-03T19:00:00Z" });
    const overlay = new TrafiklabSwedenTimetableOverlay("key", "https://example.test", async (input) => {
      const path = new URL(String(input)).pathname;
      if (path.includes("/departures/740000001/")) return Response.json({ departures: [] });
      if (path.includes("/departures/740000003/")) return Response.json({ departures: [{
        scheduled: "2026-08-03T22:05:00", realtime: "2026-08-03T22:11:00", delay: 360,
        is_realtime: true,
        route: { name: "Öresundståg", designation: "803", transport_mode: "TRAIN", direction: "Østerport" },
        trip: { trip_id: "known", start_date: "2026-08-03", technical_number: 803 },
        scheduled_platform: { designation: "1" }, realtime_platform: { designation: "9" },
      }] });
      return Response.json({ calls: [] });
    }, () => new Date(current.fetchedAt));
    expect(await overlay.platformUpdates(current)).toContainEqual(expect.objectContaining({
      stationId: "eu:transitous:se-Trafiklab_740000003", expectedPlatform: "9",
    }));
  });

  it("bridges a Transitous trip through official station time and train number, including platform notifications", async () => {
    const requests: string[] = [];
    const fetcher: typeof fetch = async (input) => {
      const url = new URL(String(input));
      requests.push(url.toString());
      expect(url.searchParams.get("key")).toBe("platform-key");
      if (url.pathname.includes("/departures/740000003/")) {
        return Response.json({
          timestamp: "2026-08-03T22:01:44",
          departures: [
            {
              scheduled: "2026-08-03T22:05:00",
              realtime: "2026-08-03T22:11:00",
              delay: 360,
              canceled: false,
              route: {
                name: "Öresundståg",
                designation: "803",
                transport_mode: "TRAIN",
                direction: "Østerport",
              },
              trip: { trip_id: "121120000391908173", start_date: "2026-08-03", technical_number: 803 },
              scheduled_platform: { designation: "1b" },
              realtime_platform: { designation: "2a" },
              alerts: [{ type: "TECHNICAL_PROBLEM", title: "Försening", text: "Fordonsfel" }],
              is_realtime: true,
            },
            {
              scheduled: "2026-08-03T22:05:00",
              realtime: "2026-08-03T22:05:00",
              delay: 0,
              canceled: false,
              route: {
                name: "Other train",
                designation: "999",
                transport_mode: "TRAIN",
                direction: "Lund",
              },
              trip: { trip_id: "other", start_date: "2026-08-03" },
            },
          ],
        });
      }
      if (url.pathname.includes("/trips/121120000391908173/2026-08-03")) {
        return Response.json({
          calls: [
            {
              scheduledDeparture: "2026-08-03T22:05:00",
              realtimeDeparture: "2026-08-03T22:11:00",
              departureDelay: 360,
              departureCanceled: false,
              stop: { area_id: "740000003", name: "Malmö Centralstation" },
              scheduled_platform: { designation: "1b" },
              realtime_platform: { designation: "2a" },
              alerts: [{ type: "TECHNICAL_PROBLEM", title: "Försening", text: "Fordonsfel" }],
              is_realtime: true,
            },
            {
              scheduledArrival: "2026-08-03T22:28:00",
              realtimeArrival: "2026-08-03T22:30:00",
              arrivalDelay: 120,
              arrivalCanceled: true,
              stop: { area_id: "860000858", name: "CPH Airport" },
              scheduled_platform: { designation: "2" },
              realtime_platform: { designation: "2" },
              alerts: [],
              is_realtime: true,
            },
          ],
        });
      }
      return new Response("not found", { status: 404 });
    };
    const overlay = new TrafiklabSwedenTimetableOverlay(
      "platform-key",
      "https://realtime-api.trafiklab.test/v1",
      fetcher,
      () => new Date("2026-08-03T20:01:44.000Z"),
    );
    const previous = trip();
    const current = await new TripSnapshotEnricher([overlay]).enrich(previous);

    expect(current.stops[0]).toMatchObject({
      plannedPlatform: "1b",
      expectedPlatform: "2a",
      platformSource: "Trafiklab Realtime APIs",
      expectedDeparture: "2026-08-03T20:11:00.000Z",
    });
    expect(current.stops[1]).toMatchObject({
      plannedPlatform: "2",
      expectedPlatform: "2",
      platformSource: "Trafiklab Realtime APIs",
      expectedArrival: "2026-08-03T20:30:00.000Z",
      cancelled: true,
    });
    expect(current.alertIds).toHaveLength(1);
    expect(current.alertIds[0]).toMatch(/^trafiklab-se-api:121120000391908173:/u);
    expect(diffSnapshots(previous, current, defaultPushPreferences)).toEqual(expect.arrayContaining([
      expect.objectContaining({ kind: "platform-change", stopId: previous.stops[0]!.stationId }),
      expect.objectContaining({ kind: "delay-threshold", newValue: "6" }),
      expect.objectContaining({ kind: "cancellation", stopId: previous.stops[1]!.stationId }),
      expect.objectContaining({ kind: "disruption" }),
    ]));
    expect(requests).toHaveLength(2);
    expect(requests[0]).toContain("/departures/740000003/2026-08-03T22:05");
    expect(requests[1]).toContain("/trips/121120000391908173/2026-08-03");
  });

  it("does not query the API for a trip outside the Trafiklab Sweden source", async () => {
    const requests: string[] = [];
    const overlay = new TrafiklabSwedenTimetableOverlay("platform-key", "https://trafiklab.test/v1", async (input) => {
      requests.push(String(input));
      return Response.json({});
    });
    const other = { ...trip(), nativeId: "20260803_22:05_no-Entur_803" };
    expect(await overlay.platformUpdates(other)).toEqual([]);
    expect(requests).toEqual([]);
  });
});
