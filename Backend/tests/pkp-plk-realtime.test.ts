import { afterEach, describe, expect, it, vi } from "vitest";
import { diffSnapshots } from "../src/domain/events.js";
import { defaultPushPreferences, type TripSnapshot } from "../src/domain/snapshot.js";
import { TripSnapshotEnricher } from "../src/providers/platform-overlay.js";
import { PKPPLKRealtimeOverlay } from "../src/providers/pkp-plk-realtime.js";

function trip(): TripSnapshot {
  return {
    id: "eu:transitous:ic-1308",
    source: "transitous",
    nativeId: "ic-1308",
    serviceDate: "2026-07-21",
    operatorName: "PKP Intercity",
    product: "IC 1308",
    headsign: "Kraków Główny",
    fetchedAt: "2026-07-21T09:55:00.000Z",
    alertIds: [],
    stops: [{
      stationId: "eu:transitous:pl-warszawa-centralna",
      stationName: "Warszawa Centralna",
      countryCode: "PL",
      latitude: 52.229,
      longitude: 21.003,
      sequence: 1,
      scheduledArrival: null,
      scheduledDeparture: "2026-07-21T10:00:00.000Z",
      expectedArrival: null,
      expectedDeparture: "2026-07-21T10:00:00.000Z",
      plannedPlatform: "2",
      expectedPlatform: "2",
      platformSource: "Transitous",
      platformObservedAt: null,
      cancelled: false,
      passed: false,
    }, {
      stationId: "eu:transitous:pl-krakow-glowny",
      stationName: "Kraków Główny",
      countryCode: "PL",
      latitude: 50.068,
      longitude: 19.947,
      sequence: 8,
      scheduledArrival: "2026-07-21T12:30:00.000Z",
      scheduledDeparture: null,
      expectedArrival: "2026-07-21T12:30:00.000Z",
      expectedDeparture: null,
      plannedPlatform: null,
      expectedPlatform: null,
      platformSource: null,
      platformObservedAt: null,
      cancelled: false,
      passed: false,
    }],
  };
}

function scheduleResponse() {
  return {
    generatedAt: "2026-07-21T11:55:00+02:00",
    routes: [{
      scheduleId: 2026,
      orderId: 607309466,
      trainOrderId: 607309466,
      name: "IC Wawel",
      nationalNumber: "1308",
      commercialCategorySymbol: "IC",
      operatingDates: ["2026-07-21"],
      stations: [{
        stationId: 38851,
        orderNumber: 1,
        departureTrainNumber: "1308",
        departurePlatform: "3",
        departureTrack: "7",
        departureDay: 0,
        departureTime: "12:00:00",
      }, {
        stationId: 247482,
        orderNumber: 8,
        arrivalTrainNumber: "1308",
        arrivalPlatform: "4",
        arrivalTrack: "4",
        arrivalDay: 0,
        arrivalTime: "14:30:00",
      }],
    }],
    dictionaries: { stations: {
      "38851": { id: 38851, name: "Warszawa Centralna" },
      "247482": { id: 247482, name: "Kraków Główny" },
    } },
  };
}

function fixtureFetcher(requests: Request[], cancelled = false): typeof fetch {
  return async (input, init) => {
    const request = new Request(input, init);
    requests.push(request);
    const url = new URL(request.url);
    if (url.pathname.endsWith("/dictionaries/stations")) {
      return Response.json({ stations: [
        { id: 38851, name: "Warszawa Centralna" },
        { id: 247482, name: "Kraków Główny" },
      ] });
    }
    if (url.pathname.endsWith("/schedules")) return Response.json(scheduleResponse());
    if (url.pathname.endsWith("/operations")) {
      return Response.json({
        generatedAt: "2026-07-21T12:01:00+02:00",
        trains: [{
          scheduleId: 2026,
          orderId: 607309466,
          trainOrderId: 607309466,
          operatingDate: "2026-07-21",
          trainStatus: cancelled ? "X" : "P",
          stations: [{
            stationId: 38851,
            plannedDeparture: "2026-07-21T12:00:00",
            departureDelayMinutes: 5,
            actualDeparture: null,
            isCancelled: cancelled,
          }, {
            stationId: 247482,
            plannedArrival: "2026-07-21T14:30:00",
            arrivalDelayMinutes: 5,
            actualArrival: null,
            isCancelled: cancelled,
          }],
        }],
      });
    }
    if (url.pathname.endsWith("/disruptions")) {
      return Response.json({ disruptions: cancelled ? [] : [{
        disruptionId: 771,
        affectedRoutes: [{
          scheduleId: 2026,
          orderId: 607309466,
          trainOrderId: 607309466,
          operatingDate: "2026-07-21",
          stationId: 38851,
        }],
      }] });
    }
    return new Response("not found", { status: 404 });
  };
}

afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); });

describe("PKP PLK realtime overlay", () => {
  it("joins official platforms, delays, and disruptions and drives notifications", async () => {
    const requests: Request[] = [];
    const overlay = new PKPPLKRealtimeOverlay(
      "plk-key",
      "https://plk.test/api/v1",
      fixtureFetcher(requests),
      () => new Date("2026-07-21T10:01:00.000Z"),
    );

    expect(await overlay.platformUpdates(trip())).toEqual([
      expect.objectContaining({
        stopSequence: 1,
        plannedPlatform: "2",
        expectedPlatform: "3/7",
        expectedDeparture: "2026-07-21T10:05:00.000Z",
        cancelled: false,
        source: "PKP PLK Open Data",
      }),
      expect.objectContaining({
        stopSequence: 8,
        plannedPlatform: "4/4",
        expectedPlatform: "4/4",
        expectedArrival: "2026-07-21T12:35:00.000Z",
      }),
    ]);
    expect(await overlay.tripAlertIds(trip())).toEqual(["pkp-plk:771"]);
    expect(requests.filter((request) => request.url.includes("/operations?"))).toHaveLength(1);
    expect(requests.filter((request) => request.url.includes("/schedules?"))).toHaveLength(1);
    expect(requests.every((request) => request.headers.get("X-API-Key") === "plk-key")).toBe(true);

    const previous = trip();
    const current = await new TripSnapshotEnricher([overlay]).enrich(previous);
    expect(diffSnapshots(previous, current, defaultPushPreferences)).toEqual(expect.arrayContaining([
      expect.objectContaining({ kind: "platform-change", oldValue: "2", newValue: "3/7" }),
      expect.objectContaining({ kind: "platform-change", oldValue: null, newValue: "4/4" }),
      expect.objectContaining({ kind: "delay-threshold", newValue: "5" }),
      expect.objectContaining({ kind: "disruption", newValue: "pkp-plk:771" }),
    ]));
  });

  it("maps whole-train and stop cancellations", async () => {
    const overlay = new PKPPLKRealtimeOverlay(
      "plk-key",
      "https://plk.test/api/v1",
      fixtureFetcher([], true),
      () => new Date("2026-07-21T10:01:00.000Z"),
    );

    expect(await overlay.platformUpdates(trip())).toEqual([
      expect.objectContaining({ stopSequence: 1, cancelled: true }),
      expect.objectContaining({ stopSequence: 8, cancelled: true }),
    ]);
  });

  it.each(["disruptions", "operations"])("keeps the independent feed when %s stalls", async (stalled) => {
    vi.useFakeTimers();
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    const requests: Request[] = [];
    const fixtures = fixtureFetcher(requests);
    const overlay = new PKPPLKRealtimeOverlay("plk-key", "https://plk.test/api/v1", (input, init) => {
      if (new URL(new Request(input, init).url).pathname.endsWith(`/${stalled}`)) {
        return new Promise(() => {});
      }
      return fixtures(input, init);
    }, () => new Date("2026-07-21T10:01:00Z"));
    const pending = new TripSnapshotEnricher([overlay], [], 50).enrich(trip());
    await vi.advanceTimersByTimeAsync(50);
    const value = await pending;
    if (stalled === "disruptions") {
      expect(value.stops[0]).toMatchObject({ expectedDeparture: "2026-07-21T10:05:00.000Z", expectedPlatform: "3/7" });
      expect(value.alertIds).toEqual([]);
    } else {
      expect(value.alertIds).toEqual(["pkp-plk:771"]);
      expect(value.stops).toEqual(trip().stops);
    }
    expect(requests.filter((request) => request.url.includes("/schedules?"))).toHaveLength(1);
    expect(requests.filter((request) => request.url.includes("/dictionaries/stations?"))).toHaveLength(1);
    expect(vi.getTimerCount()).toBe(0);
  });

  it.each(["disruptions", "operations"])("preserves partial results when %s fails", async (failed) => {
    const fixtures = fixtureFetcher([]);
    const overlay = new PKPPLKRealtimeOverlay("plk-key", "https://plk.test/api/v1", (input, init) => {
      if (new URL(new Request(input, init).url).pathname.endsWith(`/${failed}`)) {
        return Promise.resolve(new Response(null, { status: 503 }));
      }
      return fixtures(input, init);
    }, () => new Date("2026-07-21T10:01:00Z"));
    const value = await new TripSnapshotEnricher([overlay]).enrich(trip());
    expect(value.stops[0]?.expectedPlatform).toBe("3/7");
    expect(value.stops[0]?.expectedDeparture).toBe(failed === "operations"
      ? "2026-07-21T10:00:00.000Z" : "2026-07-21T10:05:00.000Z");
    expect(value.alertIds).toEqual(failed === "disruptions" ? [] : ["pkp-plk:771"]);
  });

  it("keeps arrival and departure updates at an intermediate stop", async () => {
    const fixtures = fixtureFetcher([]);
    const overlay = new PKPPLKRealtimeOverlay("plk-key", "https://plk.test/api/v1", async (input, init) => {
      const response = await fixtures(input, init);
      if (!new URL(new Request(input, init).url).pathname.endsWith("/operations")) return response;
      const value = await response.json() as { trains: { stations: Record<string, unknown>[] }[] };
      Object.assign(value.trains[0]!.stations[0]!, {
        plannedArrival: "2026-07-21T11:58:00", arrivalDelayMinutes: 3,
      });
      return Response.json(value);
    }, () => new Date("2026-07-21T10:01:00Z"));
    const snapshot = trip();
    snapshot.stops[0]!.scheduledArrival = "2026-07-21T09:58:00.000Z";
    expect((await overlay.platformUpdates(snapshot))[0]).toMatchObject({
      expectedArrival: "2026-07-21T10:01:00.000Z",
      expectedDeparture: "2026-07-21T10:05:00.000Z",
    });
  });

  it("rejects an ambiguous same-time route instead of guessing", async () => {
    const duplicate = scheduleResponse().routes[0]!;
    const overlay = new PKPPLKRealtimeOverlay("plk-key", "https://plk.test/api/v1", async (input, init) => {
      const request = new Request(input, init);
      const path = new URL(request.url).pathname;
      if (path.endsWith("/dictionaries/stations")) return Response.json({ stations: [
        { id: 38851, name: "Warszawa Centralna" },
        { id: 247482, name: "Kraków Główny" },
      ] });
      if (path.endsWith("/schedules")) return Response.json({
        ...scheduleResponse(),
        routes: [duplicate, { ...duplicate, scheduleId: 2027, orderId: 2 }],
      });
      return Response.json({ generatedAt: "2026-07-21T12:01:00+02:00", trains: [], disruptions: [] });
    });

    expect(await overlay.platformUpdates(trip())).toEqual([]);
  });
});
