import { describe, expect, it } from "vitest";
import { defaultPushPreferences, type TripSnapshot } from "../src/domain/snapshot.js";
import { diffSnapshots } from "../src/domain/events.js";
import { TripSnapshotEnricher } from "../src/providers/platform-overlay.js";
import { TranslinkNIOpendataOverlay } from "../src/providers/translink-ni-api.js";
import type { TranslinkNILocation } from "../src/providers/translink-ni-api-models.js";

function trip(): TripSnapshot {
  return {
    id: "eu:transitous:nir-b774",
    source: "transitous",
    nativeId: "20260721_23:15_gb-northern-ireland_50-b774",
    serviceDate: "2026-07-21",
    operatorName: "Translink",
    product: "NIR",
    headsign: "Larne Harbour",
    fetchedAt: "2026-07-21T22:10:00.000Z",
    alertIds: [],
    stops: [
      {
        stationId: "gb-nir:GC-P", stationName: "Belfast Great Central railway station", countryCode: "GB",
        latitude: 54.594, longitude: -5.936, sequence: 1,
        scheduledArrival: null, scheduledDeparture: "2026-07-21T22:15:00.000Z",
        expectedArrival: null, expectedDeparture: "2026-07-21T22:15:00.000Z",
        plannedPlatform: "1", expectedPlatform: "1", platformSource: "Transitous",
        platformObservedAt: null, cancelled: false, passed: false,
      },
      {
        stationId: "gb-nir:CH-P", stationName: "City Hospital", countryCode: "GB",
        latitude: 54.588, longitude: -5.941, sequence: 2,
        scheduledArrival: "2026-07-21T22:18:00.000Z", scheduledDeparture: "2026-07-21T22:18:00.000Z",
        expectedArrival: "2026-07-21T22:18:00.000Z", expectedDeparture: "2026-07-21T22:18:00.000Z",
        plannedPlatform: null, expectedPlatform: null, platformSource: "Transitous",
        platformObservedAt: null, cancelled: false, passed: false,
      },
      {
        stationId: "gb-nir:LR-P", stationName: "Larne Harbour Railway Station", countryCode: "GB",
        latitude: 54.847, longitude: -5.796, sequence: 3,
        scheduledArrival: "2026-07-21T23:20:00.000Z", scheduledDeparture: null,
        expectedArrival: "2026-07-21T23:20:00.000Z", expectedDeparture: null,
        plannedPlatform: null, expectedPlatform: null, platformSource: "Transitous",
        platformObservedAt: null, cancelled: false, passed: false,
      },
    ],
  };
}

function point(
  id: string,
  name: string,
  plannedArrival: string | undefined,
  plannedDeparture: string | undefined,
  estimatedArrival: string | undefined,
  estimatedDeparture: string | undefined,
  plannedPlatform: string,
  expectedPlatform: string,
): TranslinkNILocation {
  return {
    id, name, type: "platform", coord: [54.6, -5.9],
    ...(plannedArrival === undefined ? {} : { arrivalTimePlanned: plannedArrival }),
    ...(plannedDeparture === undefined ? {} : { departureTimePlanned: plannedDeparture }),
    ...(estimatedArrival === undefined ? {} : { arrivalTimeEstimated: estimatedArrival }),
    ...(estimatedDeparture === undefined ? {} : { departureTimeEstimated: estimatedDeparture }),
    properties: { stoppingPointPlanned: plannedPlatform, platform: expectedPlatform },
  };
}

function journey(overrides: Record<string, unknown> = {}) {
  const stopSequence = [
    point(
      "GC-2", "Belfast, Grand Central Station", undefined, "2026-07-21T22:15:00.000Z",
      undefined, "2026-07-21T22:20:00.000Z", "1", "2",
    ),
    point(
      "CH-1", "City Hospital Train Station", "2026-07-21T22:18:00.000Z",
      "2026-07-21T22:18:00.000Z", "2026-07-21T22:23:00.000Z",
      "2026-07-21T22:23:00.000Z", "1", "1",
    ),
    point(
      "LR-2", "Larne Harbour Train Station", "2026-07-21T23:20:00.000Z", undefined,
      "2026-07-21T23:27:00.000Z", undefined, "1", "2",
    ),
  ];
  return {
    interchanges: 0,
    legs: [{
      isRealtimeControlled: true,
      realtimeStatus: ["MONITORED"],
      origin: stopSequence[0],
      destination: stopSequence[2],
      transportation: {
        id: "rai:90004: :H:r13",
        name: "Rail Larne Line",
        product: { class: 0, name: "Rail" },
        operator: { id: "RailNI", name: "NIRailways" },
        destination: { id: "LR", name: "Larne Harbour Train Station", type: "stop" },
        properties: { trainNumber: "500400" },
      },
      stopSequence,
      infos: [{
        id: "ems-22", version: 4, type: "lineInfo",
        infoLinks: [{ title: "Signal failure near Belfast" }],
      }],
      ...overrides,
    }],
  };
}

function fetcher(
  journeys = [journey()],
  requests: Request[] = [],
  stationOverride?: (name: string) => unknown,
): typeof fetch {
  return async (input, init) => {
    const request = new Request(input, init);
    requests.push(request);
    expect(request.headers.get("X-API-TOKEN")).toBe("dedicated-token");
    const url = new URL(request.url);
    if (url.pathname.endsWith("/XML_STOPFINDER_REQUEST")) {
      const name = url.searchParams.get("name_sf") ?? "";
      if (stationOverride !== undefined) return Response.json(stationOverride(name));
      const isOrigin = name.includes("Grand Central");
      return Response.json({
        locations: [
          {
            id: isOrigin ? "10011881" : "10009999",
            name: isOrigin ? "The Village, Belfast Grand Central Busway" : "Larne Bus Station",
            type: "stop", coord: [54.59, -5.94], productClasses: [5],
          },
          {
            id: isOrigin ? "GC" : "LR",
            name: isOrigin ? "Belfast, Grand Central Station" : "Larne Harbour Train Station",
            type: "stop", coord: isOrigin ? [54.5948, -5.9391] : [54.846, -5.796],
            productClasses: [0], properties: { stopId: isOrigin ? "10000055" : "10000035" },
          },
        ],
      });
    }
    if (url.pathname.endsWith("/XML_TRIP_REQUEST2")) return Response.json({ journeys });
    return new Response("not found", { status: 404 });
  };
}

describe("TranslinkNIOpendataOverlay", () => {
  it("uses the dedicated API contract and maps full-route platforms, times, and alerts", async () => {
    const requests: Request[] = [];
    const overlay = new TranslinkNIOpendataOverlay(
      "dedicated-token", "https://translink.test/Ext_API", fetcher(undefined, requests),
      () => new Date("2026-07-21T22:12:00.000Z"),
    );
    const previous = trip();
    const current = await new TripSnapshotEnricher([overlay]).enrich(previous);
    const events = diffSnapshots(previous, current, defaultPushPreferences);

    expect(current.stops[0]).toMatchObject({
      plannedPlatform: "1",
      expectedPlatform: "2",
      expectedDeparture: "2026-07-21T22:20:00.000Z",
      platformSource: "Translink NI Opendata API",
      platformObservedAt: "2026-07-21T22:12:00.000Z",
    });
    expect(current.stops[1]).toMatchObject({
      expectedArrival: "2026-07-21T22:23:00.000Z",
      expectedDeparture: "2026-07-21T22:23:00.000Z",
    });
    expect(current.stops[2]).toMatchObject({
      expectedPlatform: "2",
      expectedArrival: "2026-07-21T23:27:00.000Z",
    });
    expect(current.alertIds).toContain("translink-ni:500400:ems-22:4");
    expect(events).toEqual(expect.arrayContaining([
      expect.objectContaining({ kind: "platform-change", oldValue: "1", newValue: "2" }),
      expect.objectContaining({ kind: "delay-threshold", stopId: "gb-nir:GC-P", newValue: "5" }),
      expect.objectContaining({ kind: "disruption" }),
    ]));

    const stationRequests = requests.filter((request) => request.url.includes("XML_STOPFINDER_REQUEST"));
    const tripRequests = requests.filter((request) => request.url.includes("XML_TRIP_REQUEST2"));
    expect(stationRequests).toHaveLength(2);
    expect(tripRequests).toHaveLength(1);
    expect(new URL(stationRequests[0]!.url).searchParams.get("name_sf"))
      .toBe("Belfast Grand Central");
    const query = new URL(tripRequests[0]!.url).searchParams;
    expect(Object.fromEntries(query)).toMatchObject({
      ext_macro: "trip",
      name_origin: "GC",
      name_destination: "LR",
      itdDate: "20260721",
      itdTime: "2305",
      includedMeans: "0",
      genC: "0",
      useRealtime: "1",
    });

    await new TripSnapshotEnricher([overlay]).enrich(previous);
    expect(requests).toHaveLength(3);
  });

  it("maps whole-service and individual-stop cancellations", async () => {
    const cancelledLeg = journey({ realtimeStatus: ["CANCELLED"] });
    const whole = new TranslinkNIOpendataOverlay(
      "dedicated-token", "https://translink.test/Ext_API", fetcher([cancelledLeg]),
    );
    const wholeCurrent = await new TripSnapshotEnricher([whole]).enrich(trip());
    expect(wholeCurrent.stops.every((stop) => stop.cancelled)).toBe(true);

    const partialJourney = journey();
    const partialLeg = partialJourney.legs[0]!;
    partialLeg.stopSequence[1]!.realtimeStatus = ["SKIPPED"];
    const partial = new TranslinkNIOpendataOverlay(
      "dedicated-token", "https://translink.test/Ext_API", fetcher([partialJourney]),
    );
    const partialCurrent = await new TripSnapshotEnricher([partial]).enrich(trip());
    expect(partialCurrent.stops.map((stop) => stop.cancelled)).toEqual([false, true, false]);
  });

  it("rejects ambiguous services and ambiguous station matches instead of guessing", async () => {
    const ambiguousTrips = [journey(), journey({
      transportation: {
        ...journey().legs[0]!.transportation,
        id: "rai:other",
      },
    })];
    const serviceOverlay = new TranslinkNIOpendataOverlay(
      "dedicated-token", "https://translink.test/Ext_API", fetcher(ambiguousTrips),
    );
    expect(await serviceOverlay.platformUpdates(trip())).toEqual([]);

    const requests: Request[] = [];
    const stationOverlay = new TranslinkNIOpendataOverlay(
      "dedicated-token", "https://translink.test/Ext_API",
      fetcher(undefined, requests, () => ({
        locations: [
          { id: "GC-A", name: "Grand Central Station", type: "stop", productClasses: [0] },
          { id: "GC-B", name: "Grand Central Station", type: "stop", productClasses: [0] },
        ],
      })),
    );
    expect(await stationOverlay.platformUpdates(trip())).toEqual([]);
    expect(requests.some((request) => request.url.includes("XML_TRIP_REQUEST2"))).toBe(false);
  });

  it("does not call the Northern Ireland API for mainland British trips", async () => {
    const requests: Request[] = [];
    const mainland = {
      ...trip(),
      nativeId: "uk-avanti-123",
      operatorName: "Avanti West Coast",
      product: "Intercity",
      stops: [{ ...trip().stops[0]!, stationName: "London Euston" }],
    };
    const overlay = new TranslinkNIOpendataOverlay(
      "dedicated-token", "https://translink.test/Ext_API", fetcher(undefined, requests),
    );
    expect(await overlay.platformUpdates(mainland)).toEqual([]);
    expect(requests).toEqual([]);
  });
});
