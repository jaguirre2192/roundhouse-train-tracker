import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";
import type { RouteGeometrySnapshot } from "../src/domain/snapshot.js";
import { AmtrakerProvider } from "../src/providers/amtraker.js";
import { RailProviderNotFoundError } from "../src/providers/provider.js";
import type { NorthAmericanIntercityRouteGeometrySource } from "../src/providers/north-american-intercity-gtfs-geometry.js";

describe("AmtrakerProvider", () => {
  it("normalizes a live-shaped trip fixture", async () => {
    const fixture = await readFile(new URL("../../Packages/TrainTrackerCore/Tests/TrainTrackerCoreTests/Fixtures/Amtraker/train.json", import.meta.url));
    const provider = new AmtrakerProvider(
      "https://example.test",
      async () => new Response(fixture, { status: 200 }),
      () => new Date("2026-07-20T18:00:00.000Z"),
    );

    const trip = await provider.fetchTrip({
      id: "us:amtraker:171-20",
      source: "amtraker",
      nativeId: "171-20",
      serviceDate: "2026-07-20",
    });

    expect(trip.product).toBe("Northeast Regional 171");
    expect(trip.stops[1]).toMatchObject({ stationId: "us:amtraker:PHL", expectedPlatform: "4" });
  });

  it("treats an empty Amtraker platform as missing from the feed, with no source credit", async () => {
    // Washington Union, 2026-09-15 20:50:52Z: Amtraker returned "" while the station board showed Track 17.
    const body = JSON.stringify({
      "2120": [{
        trainID: "2120-15", trainNum: "2120", routeName: "Acela", provider: "Amtrak",
        stations: [
          { name: "Washington Union", code: "WAS", tz: "America/New_York",
            schDep: "2026-09-15T17:05:00-04:00", dep: "2026-09-15T17:05:00-04:00", status: "Enroute", platform: "" },
          { name: "New York Penn", code: "NYP", tz: "America/New_York",
            schArr: "2026-09-15T20:05:00-04:00", arr: "2026-09-15T20:05:00-04:00", status: "Enroute", platform: "  " },
        ],
      }],
    });
    const provider = new AmtrakerProvider(
      "https://example.test",
      async () => new Response(body, { status: 200 }),
      () => new Date("2026-09-15T20:50:52.000Z"),
    );

    const trip = await provider.fetchTrip({
      id: "us:amtraker:2120-15",
      source: "amtraker",
      nativeId: "2120-15",
      serviceDate: "2026-09-15",
    });

    expect(trip.stops[0]).toMatchObject({ plannedPlatform: null, expectedPlatform: null, platformSource: null });
    expect(trip.stops[1]).toMatchObject({ plannedPlatform: null, expectedPlatform: null, platformSource: null });
  });

  it("attaches a conservatively matched official GTFS shape", async () => {
    const fixture = await readFile(new URL("../../Packages/TrainTrackerCore/Tests/TrainTrackerCoreTests/Fixtures/Amtraker/train.json", import.meta.url));
    const geometry: RouteGeometrySnapshot = {
      source: "Amtrak GTFS",
      segments: [{
        encodedPolyline: "_p~iF~ps|U_ulLnnqC_mqNvxq`@",
        precision: 5,
        pointCount: 3,
      }],
    };
    const requests: Array<{
      operatorName: string;
      trainNumber: string;
      stops: readonly { code: string; latitude: number | null; longitude: number | null }[];
    }> = [];
    const geometrySource: NorthAmericanIntercityRouteGeometrySource = {
      async geometryFor(operatorName, trainNumber, stops) {
        requests.push({ operatorName, trainNumber, stops });
        return geometry;
      },
    };
    const provider = new AmtrakerProvider(
      "https://example.test",
      async () => new Response(fixture, { status: 200 }),
      () => new Date("2026-07-20T18:00:00.000Z"),
      geometrySource,
    );

    const trip = await provider.fetchTrip({
      id: "us:amtraker:171-20",
      source: "amtraker",
      nativeId: "171-20",
      serviceDate: "2026-07-20",
    });

    expect(requests).toEqual([{
      operatorName: "Amtrak",
      trainNumber: "171",
      stops: [
        { code: "NYP", latitude: null, longitude: null },
        { code: "PHL", latitude: null, longitude: null },
      ],
    }]);
    expect(trip.routeGeometry).toEqual(geometry);
  });

  it("does not request generated geometry unless a source is explicitly enabled", async () => {
    const fixture = await readFile(new URL("../../Packages/TrainTrackerCore/Tests/TrainTrackerCoreTests/Fixtures/Amtraker/train.json", import.meta.url));
    const provider = new AmtrakerProvider(
      "https://example.test",
      async () => new Response(fixture, { status: 200 }),
      () => new Date("2026-07-20T18:00:00.000Z"),
    );

    const trip = await provider.fetchTrip({
      id: "us:amtraker:171-20",
      source: "amtraker",
      nativeId: "171-20",
      serviceDate: "2026-07-20",
    });

    expect(trip.routeGeometry).toBeUndefined();
  });

  it("does not promote a missing provider identity to Amtrak for geometry matching", async () => {
    const fixture = JSON.parse(await readFile(
      new URL("../../Packages/TrainTrackerCore/Tests/TrainTrackerCoreTests/Fixtures/Amtraker/train.json", import.meta.url),
      "utf8",
    )) as Record<string, Array<Record<string, unknown>>>;
    delete Object.values(fixture).flat()[0]!.provider;
    const geometrySource: NorthAmericanIntercityRouteGeometrySource = {
      async geometryFor(operatorName) {
        return operatorName === "Amtrak"
          ? { source: "incorrect", segments: [{ encodedPolyline: "abc", precision: 5, pointCount: 2 }] }
          : null;
      },
    };
    const provider = new AmtrakerProvider(
      "https://example.test",
      async () => Response.json(fixture),
      () => new Date("2026-07-20T18:00:00.000Z"),
      geometrySource,
    );

    const trip = await provider.fetchTrip({
      id: "us:amtraker:171-20",
      source: "amtraker",
      nativeId: "171-20",
      serviceDate: "2026-07-20",
    });

    expect(trip.operatorName).toBe("Amtrak");
    expect(trip.routeGeometry).toBeUndefined();
  });

  it("keeps the approximate fallback when GTFS geometry lookup fails", async () => {
    const fixture = await readFile(new URL("../../Packages/TrainTrackerCore/Tests/TrainTrackerCoreTests/Fixtures/Amtraker/train.json", import.meta.url));
    const geometrySource: NorthAmericanIntercityRouteGeometrySource = {
      async geometryFor() { throw new Error("catalog unavailable"); },
    };
    const provider = new AmtrakerProvider(
      "https://example.test",
      async () => new Response(fixture, { status: 200 }),
      () => new Date("2026-07-20T18:00:00.000Z"),
      geometrySource,
    );

    const trip = await provider.fetchTrip({
      id: "us:amtraker:171-20",
      source: "amtraker",
      nativeId: "171-20",
      serviceDate: "2026-07-20",
    });

    expect(trip.routeGeometry).toBeUndefined();
  });

  it("serves canonical station discovery and departure boards", async () => {
    const stations = await readFile(new URL("../../Packages/TrainTrackerCore/Tests/TrainTrackerCoreTests/Fixtures/Amtraker/stations.json", import.meta.url));
    const trains = await readFile(new URL("../../Packages/TrainTrackerCore/Tests/TrainTrackerCoreTests/Fixtures/Amtraker/train.json", import.meta.url));
    const provider = new AmtrakerProvider(
      "https://example.test",
      async (input) => new Response(String(input).endsWith("/stations") ? stations : trains, { status: 200 }),
      () => new Date("2026-07-20T17:00:00.000Z"),
    );

    await expect(provider.searchStations("Philadelphia")).resolves.toContainEqual(expect.objectContaining({
      id: "us:amtraker:PHL",
      countryCode: "US",
    }));
    await expect(provider.fetchBoard({
      stationId: "us:amtraker:PHL",
      source: "amtraker",
      nativeId: "PHL",
      at: "2026-07-20T17:00:00.000Z",
      direction: "departures",
    })).resolves.toContainEqual(expect.objectContaining({
      trip: expect.objectContaining({ id: "us:amtraker:171-20" }),
      stop: expect.objectContaining({ stationId: "us:amtraker:PHL" }),
    }));
  });

  it("throws the typed provider error when a requested trip is absent", async () => {
    const provider = new AmtrakerProvider(
      "https://example.test",
      async () => Response.json({}),
    );

    await expect(provider.fetchTrip({
      id: "us:amtraker:missing",
      source: "amtraker",
      nativeId: "missing",
      serviceDate: "2026-07-20",
    })).rejects.toBeInstanceOf(RailProviderNotFoundError);
  });

  it("fails closed instead of substituting another train", async () => {
    const fixture = await readFile(new URL("../../Packages/TrainTrackerCore/Tests/TrainTrackerCoreTests/Fixtures/Amtraker/train.json", import.meta.url));
    const provider = new AmtrakerProvider(
      "https://example.test",
      async () => new Response(fixture, { status: 200 }),
      () => new Date("2026-07-20T18:00:00.000Z"),
    );

    await expect(provider.fetchTrip({
      id: "us:amtraker:999-20",
      source: "amtraker",
      nativeId: "999-20",
      serviceDate: "2026-07-20",
    })).rejects.toBeInstanceOf(RailProviderNotFoundError);
  });
});
