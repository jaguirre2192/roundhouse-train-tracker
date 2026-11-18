import { describe, expect, it } from "vitest";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { AmtrakerProvider } from "../src/providers/amtraker.js";
import { AmtrakerVehiclePositionOverlay, amtrakTrainNumber, isAmtrakSnapshot } from "../src/providers/amtraker-vehicle-position.js";

// Train 2120, 2026-09-15: a journey-search trip showed "Position unavailable" while Amtraker had GPS near BWI.
function amtraker(id: string, departure: string, extra: Record<string, unknown> = {}) {
  return {
    trainID: id, trainNum: "2120", routeName: "Acela", provider: "Amtrak",
    lat: 39.176010356179454, lon: -76.69444495410441, heading: "NE",
    updatedAt: "2026-09-15T17:26:31-04:00", lastValTS: "2026-09-15T17:25:41-04:00",
    stations: [{ name: "Washington Union", code: "WAS", schDep: departure, dep: departure, status: "Departed", platform: "" }],
    ...extra,
  };
}

const now = () => new Date("2026-09-15T21:28:00.000Z");

const transitous: TripSnapshot = {
  id: "us:transitous:20_us-Amtrak_285229",
  source: "transitous",
  nativeId: "20_us-Amtrak_285229",
  serviceDate: "2026-09-15",
  operatorName: "Amtrak",
  product: "2120",
  headsign: "Ny Moynihan Train Hall At Penn Station",
  fetchedAt: "2026-09-15T21:27:00.000Z",
  alertIds: [],
  stops: [{
    stationId: "us:transitous:us-Amtrak_WAS", stationName: "Washington Union Station", countryCode: "US",
    latitude: 38.897, longitude: -77.006, sequence: 1, scheduledArrival: null,
    scheduledDeparture: "2026-09-15T21:05:00.000Z", expectedArrival: null, expectedDeparture: null,
    plannedPlatform: null, expectedPlatform: null, platformSource: null, platformObservedAt: null,
    cancelled: false, passed: true,
  }],
};

function overlay(body: unknown, requests: string[] = []) {
  return new AmtrakerVehiclePositionOverlay(
    "https://example.test",
    async (input) => {
      requests.push(String(input));
      return new Response(JSON.stringify(body), { status: 200 });
    },
    now,
  );
}

describe("Amtrak vehicle positions", () => {
  it("attaches the same day's Amtraker GPS to a journey-search Amtrak trip", async () => {
    const requests: string[] = [];
    const positions = await overlay({
      "2120": [
        amtraker("2120-14", "2026-09-14T17:05:00-04:00", { lat: 40, lon: -75 }),
        amtraker("2120-15", "2026-09-15T17:05:00-04:00"),
      ],
    }, requests).positionUpdates(transitous);

    expect(requests).toEqual(["https://example.test/trains/2120"]);
    expect(isAmtrakSnapshot(transitous)).toBe(true);
    expect(amtrakTrainNumber(transitous)).toBe("2120");
    expect(positions).toEqual([{
      latitude: 39.176010356179454, longitude: -76.69444495410441, heading: 45, source: "real",
      confidence: 1, asOf: "2026-09-15T21:25:41.000Z", provider: "Amtraker",
    }]);
  });

  it("returns nothing for another day, an ambiguous match, missing GPS, stale GPS, or non-Amtrak trips", async () => {
    await expect(overlay({ "2120": [amtraker("2120-16", "2026-09-16T17:05:00-04:00")] }).positionUpdates(transitous)).resolves.toEqual([]);
    await expect(overlay({ "2120": [
      amtraker("2120-15", "2026-09-15T17:05:00-04:00"),
      amtraker("2120-15b", "2026-09-15T17:05:30-04:00"),
    ] }).positionUpdates(transitous)).resolves.toEqual([]);
    await expect(overlay({ "2120": [amtraker("2120-15", "2026-09-15T17:05:00-04:00", { lat: null, lon: null })] }).positionUpdates(transitous)).resolves.toEqual([]);
    await expect(overlay({ "2120": [amtraker("2120-15", "2026-09-15T17:05:00-04:00", { lastValTS: "2026-09-15T15:00:00-04:00" })] }).positionUpdates(transitous)).resolves.toEqual([]);

    const requests: string[] = [];
    await expect(overlay({}, requests).positionUpdates({ ...transitous, operatorName: "VIA Rail", nativeId: "1_ca-viarail_60" })).resolves.toEqual([]);
    expect(requests).toEqual([]);
  });

  it("ignores the same time at an unrelated station and rejects undated or future GPS", async () => {
    const elsewhere = { ...amtraker("2120-15", "2026-09-15T17:05:00-04:00"),
      stations: [{ name: "Philadelphia 30th Street", code: "PHL", schDep: "2026-09-15T17:05:00-04:00" }] };
    await expect(overlay({ "2120": [elsewhere] }).positionUpdates(transitous)).resolves.toEqual([]);
    await expect(overlay({ "2120": [amtraker("2120-15", "2026-09-15T17:05:00-04:00", { lastValTS: null, updatedAt: null })] })
      .positionUpdates(transitous)).resolves.toEqual([]);
    await expect(overlay({ "2120": [amtraker("2120-15", "2026-09-15T17:05:00-04:00", { lastValTS: "2026-09-15T18:30:00-04:00" })] })
      .positionUpdates(transitous)).resolves.toEqual([]);
    await expect(overlay({ "2120": [amtraker("2120-15", "2026-09-15T17:05:00-04:00", { lat: 0, lon: 0 })] })
      .positionUpdates(transitous)).resolves.toEqual([]);
  });

  it("does not attach next month's same-ID instance to an older saved trip", async () => {
    const august = { ...transitous, serviceDate: "2026-08-15",
      stops: transitous.stops.map((stop) => ({ ...stop, scheduledDeparture: "2026-08-15T21:05:00.000Z" })) };
    await expect(overlay({ "2120": [amtraker("2120-15", "2026-09-15T17:05:00-04:00")] }).positionUpdates(august)).resolves.toEqual([]);
  });

  it("includes GPS in Amtraker-sourced trip snapshots", async () => {
    const provider = new AmtrakerProvider(
      "https://example.test",
      async (input) => String(input).endsWith("/stations")
        ? new Response("{}", { status: 200 })
        : new Response(JSON.stringify({ "2120": [amtraker("2120-15", "2026-09-15T17:05:00-04:00")] }), { status: 200 }),
      now,
    );
    const trip = await provider.fetchTrip({ id: "us:amtraker:2120-15", source: "amtraker", nativeId: "2120-15", serviceDate: "2026-09-15" });
    expect(trip.positions?.[0]).toMatchObject({ latitude: 39.176010356179454, source: "real", provider: "Amtraker" });
  });
});
