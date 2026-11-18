import { describe, expect, it } from "vitest";
import { TransitousJourneyProvider } from "../src/providers/transitous-journeys.js";
import { decodeRailPlaceId, encodeRailPlaceId, type DecodedRailPlaceId } from "../src/providers/rail-place-id.js";
import { transitousJourneyEndpointAlias } from "../src/providers/transitous-search-aliases.js";

const mergedOriente = "eu-blablacar-bus_ALE";
const railOriente = "pt-Comboios-de-Portugal(CP)_94_31039";
const campanha = "pt-Comboios-de-Portugal(CP)_94_2006";
const fixedNow = new Date("2026-11-12T23:37:00Z");
const departure = "2026-11-13T07:09:00Z";
const arrival = "2026-11-13T09:48:00Z";

function station(nativeId: string, countryCode = "PT"): DecodedRailPlaceId {
  return { provider: "transitous", kind: "station", nativeId, countryCode, latitude: null, longitude: null };
}

function request(origin: string, destination: string) {
  return {
    originId: encodeRailPlaceId(station(origin)), destinationId: encodeRailPlaceId(station(destination)),
    time: "2026-11-13T07:00:00Z", arriveBy: false, maxTransfers: 0, providerCursor: null,
  };
}

// Reduced from the November 12 live response: the merged geocode node is a
// 490 m / seven-minute walk from CP's actual boarding stop in the same station.
function orientePlan(fromPlace: string) {
  const from = {
    name: "Lisboa Oriente", stopId: railOriente, lat: 38.767757, lon: -9.099094,
    tz: "Europe/Lisbon", departure, scheduledDeparture: departure,
  };
  const to = {
    name: "Porto Campanha", stopId: campanha, lat: 41.14872, lon: -8.584835,
    tz: "Europe/Lisbon", arrival, scheduledArrival: arrival,
  };
  const rail = {
    mode: "REGIONAL_RAIL", routeType: 2, from, to, startTime: departure, endTime: arrival, duration: 9540,
    realTime: false, agencyName: "CP - Comboios de Portugal", routeShortName: "AP", tripShortName: "131",
    tripId: "20261113_07:00_pt-Comboios-de-Portugal(CP)_131_20260102",
  };
  const access = {
    mode: "WALK", duration: 420, distance: 490, startTime: "2026-11-13T07:02:00Z", endTime: departure,
    from: { name: "Lisbon - Oriente", stopId: mergedOriente, lat: 38.76762, lon: -9.101271, tz: "Europe/Lisbon" },
    to: from,
  };
  return { itineraries: [{
    startTime: fromPlace === mergedOriente ? access.startTime : departure,
    endTime: arrival, duration: fromPlace === mergedOriente ? 9960 : 9540, transfers: 0,
    legs: fromPlace === mergedOriente ? [access, rail] : [rail],
  }] };
}

describe("Portuguese railway station identity", () => {
  it("searches and plans Oriente using CP's actual boarding stop", async () => {
    let plannedFrom: string | null = null;
    const provider = new TransitousJourneyProvider("https://provider.test", async (input) => {
      const url = new URL(String(input));
      if (url.pathname.endsWith("geocode")) return Response.json([{
        type: "STOP", name: "Lisboa Oriente", id: mergedOriente, country: "PT",
        modes: ["COACH", "REGIONAL_RAIL", "SUBURBAN"], lat: 38.76762, lon: -9.101271, tz: "Europe/Lisbon",
      }]);
      plannedFrom = url.searchParams.get("fromPlace");
      return Response.json(orientePlan(plannedFrom!));
    }, () => fixedNow);

    const places = await provider.searchPlaces("Lisboa Oriente", 5);
    expect(places).toHaveLength(1);
    expect(decodeRailPlaceId(places[0]!.id)).toEqual(station(railOriente));
    expect(places[0]!.location).toEqual({ latitude: 38.767757, longitude: -9.099094 });
    const result = await provider.searchJourneys({ ...request(railOriente, campanha), originId: places[0]!.id });
    expect(plannedFrom).toBe(railOriente);
    expect(result.options).toHaveLength(1);
    expect(result.options[0]).toMatchObject({ startTime: departure, endTime: arrival, transferCount: 0 });
    const segment = result.options[0]!.segments[0]!;
    expect(segment.kind).toBe("rail");
    if (segment.kind !== "rail") throw new Error("Expected CP railway segment");
    expect(segment.rail).toMatchObject({ trainNumber: "131", serviceDate: "2026-11-13", isRealtime: false });
    expect(decodeRailPlaceId(segment.rail.from.place.id).nativeId).toBe(railOriente);
    expect(decodeRailPlaceId(segment.rail.to.place.id).nativeId).toBe(campanha);
  });

  it.each(["fromPlace", "toPlace"])("repairs a cached merged Oriente ID in %s", async (field) => {
    let requested: URL | undefined;
    const provider = new TransitousJourneyProvider("https://provider.test", async (input) => {
      requested = new URL(String(input));
      return Response.json({ itineraries: [] });
    }, () => fixedNow);
    await provider.searchJourneys(field === "fromPlace" ? request(mergedOriente, campanha) : request(campanha, mergedOriente));
    expect(requested?.searchParams.get(field)).toBe(railOriente);
    expect(requested?.searchParams.get(field === "fromPlace" ? "toPlace" : "fromPlace")).toBe(campanha);
    expect(requested?.searchParams.has("radius")).toBe(false);
  });

  it("leaves unrelated stops, countries and city searches unchanged", () => {
    const values: DecodedRailPlaceId[] = [
      station("eu-blablacar-bus_OTHER"), station(mergedOriente, "FR"), station(railOriente),
      { ...station(mergedOriente), kind: "city", latitude: 38.76762, longitude: -9.101271 },
    ];
    for (const value of values) expect(transitousJourneyEndpointAlias(value)).toEqual(value);
  });
});
