import { describe, expect, it } from "vitest";
import { defaultPushPreferences, type TripSnapshot } from "../src/domain/snapshot.js";
import { diffSnapshots } from "../src/domain/events.js";
import { TripSnapshotEnricher } from "../src/providers/platform-overlay.js";
import { TranslinkNIRRealtimeOverlay } from "../src/providers/translink-nir-realtime.js";

const locations = [
  { TIPLOC: "GC", CRS: "GCA", Name: "Belfast Grand Central", TOC: ["NIR"] },
  { TIPLOC: "CH", CRS: "CHA", Name: "City Hospital", TOC: ["NIR"] },
  { TIPLOC: "LR", CRS: "LRA", Name: "Larne Harbour", TOC: ["NIR"] },
  { TIPLOC: "EUSTON", CRS: "EUS", Name: "London Euston", TOC: ["VT"] },
];

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
        stationId: "gb-nir:GC-P", stationName: "Grand Central Station", countryCode: "GB",
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

function service(overrides: Record<string, unknown> = {}) {
  return {
    UID: "500400", Headcode: "B774", ATOCCode: "NI", ATOCDesc: "Translink", Type: "D",
    Location: "GC", Platform: "2", STD: "23:15", DepTimestamp: "2026-07-21T23:15+01:00",
    ExpectedDepTimestamp: "2026-07-21T23:20+01:00", DepStatus: "Exp",
    ProcessedTimestamp: "2026-07-21T22:11:30.000Z",
    Origins: { Front: { Name: "Belfast Grand Central", TIPLOC: "GC", CRS: "GCA", DepTimestamp: "2026-07-21T23:15+01:00", ExpectedDepTimestamp: "2026-07-21T23:20+01:00", DepStatus: "Exp" } },
    Destinations: { Front: { Name: "Larne Harbour", TIPLOC: "LR", CRS: "LRA", ArrTimestamp: "2026-07-22T00:20+01:00", ExpectedArrTimestamp: "2026-07-22T00:27+01:00", ArrStatus: "Exp" } },
    CallingPoints: { Front: [{ Name: "City Hospital", TIPLOC: "CH", CRS: "CHA", ArrTimestamp: "2026-07-21T23:18+01:00", DepTimestamp: "2026-07-21T23:18+01:00", ExpectedArrTimestamp: "2026-07-21T23:23+01:00", ExpectedDepTimestamp: "2026-07-21T23:23+01:00", ArrStatus: "Exp", DepStatus: "Exp" }] },
    ...overrides,
  };
}

function fixtureFetcher(
  serviceValues = [service()],
  boardOverrides: Record<string, unknown> = { incidentSummary: "Signal failure near Belfast" },
  requests: string[] = [],
): typeof fetch {
  return async (input, init) => {
    const request = new Request(input, init);
    requests.push(request.url);
    expect(request.headers.get("x-api-key")).toBe("nir-key");
    if (request.url.endsWith("/locations")) return Response.json(locations);
    if (request.url.includes("/services/")) return Response.json({
      TIPLOC: request.url.split("/").at(-1), timestamp: "2026-07-21T22:12:00.000Z",
      services: serviceValues, ...boardOverrides,
    });
    return new Response("not found", { status: 404 });
  };
}

describe("TranslinkNIRRealtimeOverlay", () => {
  it("maps official platforms and downstream times into stable platform, delay, and disruption notifications", async () => {
    const previous = trip();
    const requests: string[] = [];
    const overlay = new TranslinkNIRRealtimeOverlay(
      "nir-key", "https://nir.test", fixtureFetcher([service()], undefined, requests),
      () => new Date("2026-07-21T22:12:00.000Z"),
    );

    const current = await new TripSnapshotEnricher([overlay]).enrich(previous);
    const events = diffSnapshots(previous, current, defaultPushPreferences);

    expect(current.stops[0]).toMatchObject({
      expectedPlatform: "2", expectedDeparture: "2026-07-21T22:20:00.000Z",
      platformSource: "Translink NIR Realtime (Open Data NI)",
      platformObservedAt: "2026-07-21T22:12:00.000Z",
    });
    expect(current.stops[1]).toMatchObject({
      expectedArrival: "2026-07-21T22:23:00.000Z",
      expectedDeparture: "2026-07-21T22:23:00.000Z",
    });
    expect(current.stops[2]).toMatchObject({ expectedArrival: "2026-07-21T23:27:00.000Z" });
    expect(current.alertIds).toEqual([expect.stringMatching(/^translink-nir:500400:[0-9a-f]{8}$/u)]);
    expect(events).toEqual(expect.arrayContaining([
      expect.objectContaining({ kind: "platform-change", oldValue: "1", newValue: "2" }),
      expect.objectContaining({ kind: "delay-threshold", stopId: "gb-nir:GC-P", newValue: "5" }),
      expect.objectContaining({ kind: "disruption" }),
    ]));

    const repeated = await new TripSnapshotEnricher([overlay]).enrich(previous);
    expect(diffSnapshots(previous, repeated, defaultPushPreferences).map((event) => event.fingerprint))
      .toEqual(events.map((event) => event.fingerprint));
    expect(requests.filter((url) => url.endsWith("/locations"))).toHaveLength(1);
    expect(requests.filter((url) => url.includes("/services/"))).toHaveLength(3);
  });

  it("maps whole-service and individual calling-point cancellations", async () => {
    const whole = new TranslinkNIRRealtimeOverlay(
      "nir-key", "https://nir.test",
      fixtureFetcher([service({ DepStatus: "Cancelled" })], {}),
    );
    const wholeCurrent = await new TripSnapshotEnricher([whole]).enrich(trip());
    expect(wholeCurrent.stops.every((stop) => stop.cancelled)).toBe(true);
    expect(diffSnapshots(trip(), wholeCurrent, defaultPushPreferences))
      .toEqual([expect.objectContaining({ kind: "cancellation", stopId: null })]);

    const point = service();
    point.CallingPoints.Front[0]!.ArrStatus = "Cancelled";
    point.CallingPoints.Front[0]!.DepStatus = "Cancelled";
    const partial = new TranslinkNIRRealtimeOverlay("nir-key", "https://nir.test", fixtureFetcher([point], {}));
    const partialCurrent = await new TripSnapshotEnricher([partial]).enrich(trip());
    expect(partialCurrent.stops.map((stop) => stop.cancelled)).toEqual([false, true, false]);
    expect(diffSnapshots(trip(), partialCurrent, defaultPushPreferences))
      .toEqual(expect.arrayContaining([
        expect.objectContaining({ kind: "cancellation", stopId: "gb-nir:CH-P" }),
      ]));
  });

  it("rejects an ambiguous same-time service instead of guessing", async () => {
    const overlay = new TranslinkNIRRealtimeOverlay(
      "nir-key", "https://nir.test", fixtureFetcher([service(), service({ UID: "other" })], {}),
    );
    expect(await overlay.platformUpdates(trip())).toEqual([]);
  });

  it("does not call the NIR API for mainland British trips", async () => {
    const requests: string[] = [];
    const mainland = { ...trip(), nativeId: "uk-avanti-123", operatorName: "Avanti West Coast", product: "Intercity" };
    mainland.stops = [{ ...mainland.stops[0]!, stationName: "London Euston" }];
    const overlay = new TranslinkNIRRealtimeOverlay("nir-key", "https://nir.test", fixtureFetcher([service()], {}, requests));
    expect(await overlay.platformUpdates(mainland)).toEqual([]);
    expect(requests).toEqual([]);
  });
});
