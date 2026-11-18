import { describe, expect, it, vi } from "vitest";
import { ChepeProvider } from "../src/providers/chepe.js";
import { RailProviderNotFoundError } from "../src/providers/provider.js";

import { syntheticChepePublication as publication, syntheticChepeSchedule } from "./fixtures/chepe-sample.js";

function fixtureProvider() {
  const fetcher = vi.fn(async () => new Response(publication, {
    status: 200,
    headers: { "content-type": "text/html" },
  }));
  return {
    fetcher,
    provider: new ChepeProvider(fetcher, () => new Date("2026-07-22T18:00:00.000Z"), syntheticChepeSchedule),
  };
}

describe("ChepeProvider", () => {
  it("discovers the five official Chepe Express stations with useful aliases", async () => {
    const { provider } = fixtureProvider();

    await expect(provider.searchStations("Chepe")).resolves.toHaveLength(5);
    await expect(provider.searchStations("Cerocahui")).resolves.toEqual([
      expect.objectContaining({
        id: "mx:chepe:bahuichivo",
        name: "Bahuichivo",
        countryCode: "MX",
        operatorHints: ["Chepe Express", "Ferromex"],
      }),
    ]);
  });

  it("serves a configured departure board and complete schedule-only trip across both time zones", async () => {
    const { fetcher, provider } = fixtureProvider();
    const board = await provider.fetchBoard({
      stationId: "mx:chepe:los-mochis",
      source: "chepe",
      nativeId: "los-mochis",
      at: "2026-07-23T13:00:00.000Z",
      direction: "departures",
    });

    expect(board).toEqual([expect.objectContaining({
      trip: {
        id: "mx:chepe:express-los-mochis-creel:2026-07-23",
        source: "chepe",
        nativeId: "express-los-mochis-creel:2026-07-23",
        serviceDate: "2026-07-23",
      },
      headsign: "Creel",
      product: "Chepe Express",
      stop: expect.objectContaining({ scheduledDeparture: "2026-07-23T17:11:00.000Z" }),
    })]);

    const trip = await provider.fetchTrip(board[0]!.trip);
    expect(trip.operatorName).toBe("Ferromex / Chepe Express");
    expect(trip.stops.map((stop) => stop.stationName)).toEqual([
      "Los Mochis", "Bahuichivo", "Creel",
    ]);
    expect(trip.stops[1]).toMatchObject({
      scheduledArrival: "2026-07-23T17:42:00.000Z",
      scheduledDeparture: "2026-07-23T17:42:00.000Z",
      expectedArrival: null,
      expectedPlatform: null,
    });
    expect(trip.stops.at(-1)?.scheduledArrival).toBe("2026-07-23T22:37:00.000Z");
    expect(fetcher).toHaveBeenCalledTimes(1);
  });

  it("honors configured suspensions", async () => {
    const { provider } = fixtureProvider();
    await expect(provider.fetchBoard({
      stationId: "mx:chepe:los-mochis",
      source: "chepe",
      nativeId: "los-mochis",
      at: "2026-05-07T13:00:00.000Z",
      direction: "departures",
    })).resolves.toEqual([]);

    await expect(provider.fetchTrip({
      id: "mx:chepe:express-los-mochis-creel:2026-05-07",
      source: "chepe",
      nativeId: "express-los-mochis-creel:2026-05-07",
      serviceDate: "2026-05-07",
    })).rejects.toBeInstanceOf(RailProviderNotFoundError);
  });

  it.each([undefined, "{}", "{"])("reports unconfigured or invalid data as unavailable, preserving station search", async input => {
    const fetcher = vi.fn(async () => new Response(publication));
    const provider = new ChepeProvider(fetcher, undefined, input);
    await expect(provider.searchStations("Chepe")).resolves.toHaveLength(5);
    await expect(provider.fetchBoard({
      stationId: "mx:chepe:creel", source: "chepe", nativeId: "creel",
      at: "2026-08-11T00:00:00Z", direction: "departures",
    })).rejects.toThrow("unavailable for this deployment");
    expect(fetcher).not.toHaveBeenCalled();
  });

  it("fails closed when the operator publication changes", async () => {
    const provider = new ChepeProvider(async () => new Response("new timetable pending"), undefined, syntheticChepeSchedule);
    await expect(provider.fetchTrip({
      id: "mx:chepe:express-los-mochis-creel:2026-07-23",
      source: "chepe",
      nativeId: "express-los-mochis-creel:2026-07-23",
      serviceDate: "2026-07-23",
    })).rejects.toThrow("refusing to serve an unverified schedule");
  });
});
