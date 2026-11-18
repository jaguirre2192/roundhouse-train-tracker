import { describe, expect, it } from "vitest";
import { diffSnapshots } from "../src/domain/events.js";
import { defaultPushPreferences, type TripSnapshot } from "../src/domain/snapshot.js";
import { MobiliteitLuRealtimeOverlay } from "../src/providers/mobiliteit-lu.js";
import { TripSnapshotEnricher } from "../src/providers/platform-overlay.js";

function trip(): TripSnapshot {
  return {
    id: "eu:transitous:cfl-re-3740",
    source: "transitous",
    nativeId: "cfl-re-3740",
    serviceDate: "2026-07-21",
    operatorName: "CFL",
    product: "CFL RE 3740",
    headsign: "Troisvierges",
    fetchedAt: "2026-07-21T18:10:00.000Z",
    alertIds: [],
    stops: [{
      stationId: "eu:transitous:luxembourg-gare",
      stationName: "Luxembourg Gare",
      countryCode: "LU",
      latitude: 49.5996,
      longitude: 6.1341,
      sequence: 1,
      scheduledArrival: null,
      scheduledDeparture: "2026-07-21T18:20:00.000Z",
      expectedArrival: null,
      expectedDeparture: "2026-07-21T18:20:00.000Z",
      plannedPlatform: "5",
      expectedPlatform: "5",
      platformSource: "Transitous",
      platformObservedAt: null,
      cancelled: false,
      passed: false,
    }, {
      stationId: "eu:transitous:mersch",
      stationName: "Mersch Gare",
      countryCode: "LU",
      latitude: 49.7483,
      longitude: 6.1067,
      sequence: 2,
      scheduledArrival: "2026-07-21T18:36:00.000Z",
      scheduledDeparture: "2026-07-21T18:37:00.000Z",
      expectedArrival: "2026-07-21T18:36:00.000Z",
      expectedDeparture: "2026-07-21T18:37:00.000Z",
      plannedPlatform: null,
      expectedPlatform: null,
      platformSource: null,
      platformObservedAt: null,
      cancelled: false,
      passed: false,
    }, {
      stationId: "eu:transitous:ettelbruck",
      stationName: "Ettelbruck Gare",
      countryCode: "LU",
      latitude: 49.8475,
      longitude: 6.1042,
      sequence: 3,
      scheduledArrival: "2026-07-21T18:50:00.000Z",
      scheduledDeparture: "2026-07-21T18:51:00.000Z",
      expectedArrival: "2026-07-21T18:50:00.000Z",
      expectedDeparture: "2026-07-21T18:51:00.000Z",
      plannedPlatform: "1",
      expectedPlatform: "1",
      platformSource: "Transitous",
      platformObservedAt: null,
      cancelled: false,
      passed: false,
    }],
  };
}

function fixtureFetcher(requests: Request[], options: { cancelled?: boolean; ambiguous?: boolean } = {}): typeof fetch {
  return async (input, init) => {
    const request = new Request(input, init);
    requests.push(request);
    const url = new URL(request.url);
    if (url.pathname.endsWith("/location.nearbystops")) {
      return Response.json({
        stopLocationOrCoordLocation: [{
          StopLocation: {
            id: "A=1@O=Luxembourg, Gare Centrale@L=200405000@",
            extId: "200405000",
            name: "Luxembourg, Gare Centrale",
            lat: 49.5997,
            lon: 6.1342,
            dist: 20,
          },
        }],
      });
    }
    const departure = {
      name: "RE 3740",
      stop: "Luxembourg, Gare Centrale",
      stopid: "A=1@O=Luxembourg, Gare Centrale@L=200405000@",
      date: "2026-07-21",
      time: "20:20:00",
      tz: 120,
      direction: "Troisvierges",
      track: "5",
      rtTrack: "8",
      rtDate: "2026-07-21",
      rtTime: "20:27:00",
      rtTz: 120,
      ProductAtStop: { name: "RE 3740", displayNumber: "3740", catOut: "RE" },
      Messages: { Message: [{ id: "him-3740", act: true, head: "Engineering work" }] },
      Stops: { Stop: [{
        id: "A=1@O=Luxembourg, Gare Centrale@L=200405000@",
        extId: "200405000",
        name: "Luxembourg, Gare Centrale",
        lat: 49.5997,
        lon: 6.1342,
        routeIdx: 0,
        depDate: "2026-07-21",
        depTime: "20:20:00",
        depTz: 120,
        rtDepDate: "2026-07-21",
        rtDepTime: "20:27:00",
        rtDepTz: 120,
        depTrack: "5",
        rtDepTrack: "8",
      }, {
        id: "A=1@O=Mersch, Gare@L=200405010@",
        extId: "200405010",
        name: "Mersch, Gare",
        lat: 49.7483,
        lon: 6.1067,
        routeIdx: 1,
        arrDate: "2026-07-21",
        arrTime: "20:36:00",
        arrTz: 120,
        depDate: "2026-07-21",
        depTime: "20:37:00",
        depTz: 120,
        rtArrDate: "2026-07-21",
        rtArrTime: "20:43:00",
        rtArrTz: 120,
        rtDepDate: "2026-07-21",
        rtDepTime: "20:44:00",
        rtDepTz: 120,
        depPlatform: { text: "2" },
        rtDepPlatform: { text: "2" },
        cancelled: options.cancelled ?? false,
      }, {
        id: "A=1@O=Ettelbruck, Gare@L=200405020@",
        extId: "200405020",
        name: "Ettelbruck, Gare",
        lat: 49.8475,
        lon: 6.1042,
        routeIdx: 2,
        arrDate: "2026-07-21",
        arrTime: "20:50:00",
        arrTz: 120,
        rtArrDate: "2026-07-21",
        rtArrTime: "20:57:00",
        rtArrTz: 120,
        arrTrack: "1",
        rtArrTrack: "1",
      }] },
    };
    return Response.json({ Departure: options.ambiguous ? [departure, { ...departure }] : [departure] });
  };
}

describe("mobiliteit.lu OpenAPI overlay", () => {
  it("does not attach another event's estimate or cancellation to an origin or terminal", async () => {
    const previous = trip();
    previous.stops[2]!.scheduledDeparture = null;
    previous.stops[2]!.expectedDeparture = null;
    const originalFetcher = fixtureFetcher([]);
    const fetcher: typeof fetch = async (input, init) => {
      const response = await originalFetcher(input, init);
      if (new URL(new Request(input, init).url).pathname.endsWith("/location.nearbystops")) return response;
      const body = await response.json() as { Departure: Array<{ Stops: { Stop: Array<Record<string, unknown>> } }> };
      const stops = body.Departure[0]!.Stops.Stop;
      Object.assign(stops[0]!, {
        rtArrDate: "2026-07-21", rtArrTime: "20:19:00", rtArrTz: 120, cancelledArrival: true,
      });
      // The official full pass list can include a departure beyond the snapshot's
      // terminal, as observed at Wasserbillig on the live RB83 country seed.
      Object.assign(stops[2]!, {
        rtDepDate: "2026-07-21", rtDepTime: "20:58:00", rtDepTz: 120, cancelledDeparture: true,
      });
      return Response.json(body);
    };
    const overlay = new MobiliteitLuRealtimeOverlay("test-key", "https://example.test", fetcher,
      () => new Date(previous.fetchedAt));
    const current = await new TripSnapshotEnricher([overlay]).enrich(previous);
    expect(current.stops[0]).toMatchObject({
      expectedArrival: null, expectedDeparture: "2026-07-21T18:27:00.000Z", cancelled: false,
    });
    expect(current.stops[1]).toMatchObject({
      expectedArrival: "2026-07-21T18:43:00.000Z", expectedDeparture: "2026-07-21T18:44:00.000Z",
    });
    expect(current.stops[2]).toMatchObject({
      expectedArrival: "2026-07-21T18:57:00.000Z", expectedDeparture: null, cancelled: false,
    });
  });

  function foreignArrivalTrip(): TripSnapshot {
    const current = trip();
    current.headsign = "Luxembourg Gare";
    current.stops = [
      { ...current.stops[0]!, countryCode: "DE", stationId: "de-trier", stationName: "Trier Hauptbahnhof", latitude: 49.756975, longitude: 6.651991 },
      { ...current.stops[2]!, stationId: "lu-luxembourg", stationName: "Luxembourg Gare", latitude: 49.5997, longitude: 6.1342,
        scheduledDeparture: null, expectedDeparture: null },
    ];
    return current;
  }

  function foreignArrivalFetcher(requests: string[]): typeof fetch {
    return async (input) => {
      requests.push(String(input));
      if (String(input).includes("location.nearbystops")) return Response.json({ StopLocation: [{
        id: "trier", name: "Trier, Hauptbahnhof", lat: 49.756975, lon: 6.651991,
      }] });
      return Response.json({ Departure: [{ name: "RE 3740", ProductAtStop: { displayNumber: "3740" },
        direction: "Luxembourg Gare", date: "2026-07-21", time: "20:20:00", tz: 120,
        Stops: { Stop: [{ id: "luxembourg", name: "Luxembourg, Gare Centrale", lat: 49.5997, lon: 6.1342,
          arrDate: "2026-07-21", arrTime: "20:50:00", arrTz: 120,
          rtArrDate: "2026-07-21", rtArrTime: "20:57:00", rtArrTz: 120, arrTrack: "1" }] },
      }] });
    };
  }

  it("uses a preceding foreign departure to recover the sole Luxembourg arrival from its passlist", async () => {
    const requests: string[] = [];
    const overlay = new MobiliteitLuRealtimeOverlay("key", "https://lu.test", foreignArrivalFetcher(requests));
    const result = await new TripSnapshotEnricher([overlay]).enrich(foreignArrivalTrip());
    expect(result.stops[1]).toMatchObject({ expectedArrival: "2026-07-21T18:57:00.000Z", expectedPlatform: "1", platformSource: "mobiliteit.lu OpenAPI" });
    expect(requests.some((url) => url.includes("arrivalBoard"))).toBe(false);
    expect(result.stops[0]?.platformSource).toBe("Transitous");
  });

  it("rejects a foreign-board passlist whose Luxembourg arrival belongs to another run", async () => {
    const current = foreignArrivalTrip();
    current.stops[1]!.scheduledArrival = "2026-07-21T19:50:00Z";
    const overlay = new MobiliteitLuRealtimeOverlay("key", "https://lu.test", foreignArrivalFetcher([]));
    expect(await overlay.platformUpdates(current)).toEqual([]);
  });

  it("keeps a terminal's own arrival cancellation", async () => {
    const previous = trip();
    previous.stops[2]!.scheduledDeparture = null;
    previous.stops[2]!.expectedDeparture = null;
    const originalFetcher = fixtureFetcher([]);
    const fetcher: typeof fetch = async (input, init) => {
      const response = await originalFetcher(input, init);
      if (new URL(new Request(input, init).url).pathname.endsWith("/location.nearbystops")) return response;
      const body = await response.json() as { Departure: Array<{ Stops: { Stop: Array<Record<string, unknown>> } }> };
      body.Departure[0]!.Stops.Stop[2]!.cancelledArrival = true;
      return Response.json(body);
    };
    const overlay = new MobiliteitLuRealtimeOverlay("test-key", "https://example.test", fetcher,
      () => new Date(previous.fetchedAt));
    const current = await new TripSnapshotEnricher([overlay]).enrich(previous);
    expect(current.stops[2]).toMatchObject({ expectedDeparture: null, cancelled: true });
  });

  it("still resolves the trip when a recent passed anchor has no official station match", async () => {
    const current = trip();
    current.stops.unshift({ ...current.stops[0]!, stationId: "unknown", stationName: "Unknown", latitude: 0, longitude: 0,
      sequence: 0, passed: true, scheduledDeparture: "2026-07-21T18:00:00Z", expectedDeparture: "2026-07-21T18:00:00Z" });
    const overlay = new MobiliteitLuRealtimeOverlay("key", "https://example.test", fixtureFetcher([]), () => new Date(current.fetchedAt));
    expect(await overlay.platformUpdates(current)).toContainEqual(expect.objectContaining({ stationId: "eu:transitous:luxembourg-gare", expectedPlatform: "8" }));
  });

  it("joins full-trip official times and platforms and drives dedupable notifications", async () => {
    const requests: Request[] = [];
    const overlay = new MobiliteitLuRealtimeOverlay(
      "government-access-id",
      "https://mobiliteit.test/opendata/apiserver",
      fixtureFetcher(requests),
      () => new Date("2026-07-21T18:10:00.000Z"),
    );

    const current = await new TripSnapshotEnricher([overlay]).enrich(trip());
    expect(current.stops).toEqual(expect.arrayContaining([
      expect.objectContaining({ sequence: 1, plannedPlatform: "5", expectedPlatform: "8", expectedDeparture: "2026-07-21T18:27:00.000Z" }),
      expect.objectContaining({ sequence: 2, plannedPlatform: "2", expectedPlatform: "2", expectedArrival: "2026-07-21T18:43:00.000Z" }),
      expect.objectContaining({ sequence: 3, plannedPlatform: "1", expectedPlatform: "1", expectedArrival: "2026-07-21T18:57:00.000Z" }),
    ]));
    expect(current.alertIds).toEqual(["mobiliteit-lu:him-3740"]);
    expect(requests).toHaveLength(2);
    expect(requests.every((request) => new URL(request.url).searchParams.get("accessId") === "government-access-id")).toBe(true);
    expect(new URL(requests[0]!.url).searchParams.get("type")).toBe("SE");
    const boardURL = new URL(requests.find((request) => request.url.includes("departureBoard"))!.url);
    expect(boardURL.searchParams.get("passlist")).toBe("1");
    expect(boardURL.searchParams.get("type")).toBe("DEP_STATION");
    expect(boardURL.searchParams.get("date")).toBe("2026-07-21");
    expect(boardURL.searchParams.get("time")).toBe("20:10:00");

    const first = diffSnapshots(trip(), current, defaultPushPreferences);
    const second = diffSnapshots(trip(), current, defaultPushPreferences);
    expect(first).toEqual(expect.arrayContaining([
      expect.objectContaining({ kind: "platform-change", stopId: "eu:transitous:luxembourg-gare", oldValue: "5", newValue: "8" }),
      expect.objectContaining({ kind: "platform-change", stopId: "eu:transitous:mersch", oldValue: null, newValue: "2" }),
      expect.objectContaining({ kind: "delay-threshold", stopId: "eu:transitous:luxembourg-gare", newValue: "7" }),
      expect.objectContaining({ kind: "disruption", newValue: "mobiliteit-lu:him-3740" }),
    ]));
    expect(first.map((event) => event.fingerprint)).toEqual(second.map((event) => event.fingerprint));
  });

  it("maps the provider-confirmed JourneyStatus cancellation flag", async () => {
    const fetcher = fixtureFetcher([]);
    const overlay = new MobiliteitLuRealtimeOverlay(
      "government-access-id",
      "https://mobiliteit.test/opendata/apiserver",
      async (input, init) => {
        const response = await fetcher(input, init);
        if (new URL(new Request(input, init).url).pathname.endsWith("/location.nearbystops")) return response;
        const body = await response.json() as { Departure: Array<Record<string, unknown>> };
        body.Departure[0]!.JourneyStatus = "C";
        return Response.json(body);
      },
      () => new Date("2026-07-21T18:10:00.000Z"),
    );
    const previous = trip();
    const current = await new TripSnapshotEnricher([overlay]).enrich(previous);
    expect(current.stops.every((stop) => stop.cancelled)).toBe(true);
    expect(diffSnapshots(previous, current, defaultPushPreferences)).toEqual(expect.arrayContaining([
      expect.objectContaining({ kind: "cancellation" }),
    ]));
  });

  it("maps a published per-stop cancellation", async () => {
    const overlay = new MobiliteitLuRealtimeOverlay(
      "government-access-id",
      "https://mobiliteit.test/opendata/apiserver",
      fixtureFetcher([], { cancelled: true }),
      () => new Date("2026-07-21T18:10:00.000Z"),
    );
    const previous = trip();
    const current = await new TripSnapshotEnricher([overlay]).enrich(previous);
    expect(current.stops[1]?.cancelled).toBe(true);
    expect(diffSnapshots(previous, current, defaultPushPreferences)).toContainEqual(expect.objectContaining({
      kind: "cancellation",
      stopId: "eu:transitous:mersch",
    }));
  });

  it("rejects an ambiguous journey join instead of attaching another train's platform", async () => {
    const overlay = new MobiliteitLuRealtimeOverlay(
      "government-access-id",
      "https://mobiliteit.test/opendata/apiserver",
      fixtureFetcher([], { ambiguous: true }),
      () => new Date("2026-07-21T18:10:00.000Z"),
    );
    expect(await overlay.platformUpdates(trip())).toEqual([]);
    expect(await overlay.tripAlertIds(trip())).toEqual([]);
  });
});
