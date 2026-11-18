import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";
import { TransitousJourneyProvider } from "../src/providers/transitous-journeys.js";
import { decodeRailPlaceId } from "../src/providers/rail-place-id.js";
import { transitousSearchAlias } from "../src/providers/transitous-search-aliases.js";

const baseUrl = "https://example.test";
const fixedNow = new Date("2026-07-21T19:00:00Z");

async function searchPayload(query: string, payload: unknown[]) {
  let request: URL | undefined;
  const provider = new TransitousJourneyProvider(baseUrl, async (input) => {
    request = new URL(String(input));
    return Response.json(payload);
  }, () => fixedNow);

  const places = await provider.searchPlaces(query, 20);
  return { places, request };
}

async function searchFixture(query: string, fixture: string) {
  const payload = JSON.parse(await readFile(
    new URL(`fixtures/journeys/${fixture}`, import.meta.url),
    "utf8",
  )) as unknown[];
  return searchPayload(query, payload);
}

describe("TransitousJourneyProvider common US place aliases", () => {
  it.each(["DC", "D.C.", "Washington DC", "Washington D.C.", "WAS"])(
    "normalizes %s to Washington Union Station",
    async (query) => {
      const { places, request } = await searchFixture(query, "place-search-washington-dc.json");

      expect(request?.searchParams.get("text")).toBe("Washington Union Station");
      expect(places.map((place) => place.displayName)).toEqual(["Union Station, Washington, DC"]);
      expect(places.map((place) => place.displayName)).not.toContain("WASHINGTON JUNCTION");
    },
  );

  it.each(["New York", "NYC", "New York City", "NYP"])(
    "normalizes %s to the routeable mainline Penn Station result",
    async (query) => {
      const { places, request } = await searchFixture(query, "place-search-new-york-penn.json");

      expect(request?.searchParams.get("text")).toBe("New York Penn");
      expect(places.map((place) => place.displayName)).toEqual(["NEW YORK PENN STATION"]);
    },
  );

  it.each([
    ["NY", "New York Penn", "us-Amtrak_NYP"],
    ["BOS", "Boston", "us-Amtrak_BOS"],
    ["Philly", "Philadelphia", "us-Amtrak_PHL"],
    ["30th Street", "Philadelphia", "us-Amtrak_PHL"],
    ["BAL", "Baltimore", "us-Amtrak_BAL"],
    ["BWI", "BWI Rail Station", "us-Amtrak_BWI"],
    ["NHV", "New Haven", "us-Amtrak_NHV"],
    ["PVD", "Providence", "us-Amtrak_PVD"],
    ["NWK", "Newark", "us-Amtrak_NWK"],
    ["Richmond, VA", "Richmond Staples Mill Road", "us-Amtrak_RVR"],
    ["ALX", "Alexandria", "us-Amtrak_ALX"],
    ["WIL", "Wilmington", "us-Amtrak_WIL"],
    ["CHI", "Chicago", undefined],
    ["L.A.", "Los Angeles", "us-Amtrak_LAX"],
    ["SEA", "Seattle", "us-Amtrak_SEA"],
    ["Portland, OR", "Portland", "us-Amtrak_PDX"],
    ["Portland, ME", "Portland", "us-Amtrak_POR"],
    ["SAC", "Sacramento", "us-Amtrak_SAC"],
    ["SAN", "San Diego", "us-Amtrak_SAN"],
    ["EMY", "Emeryville", "us-Amtrak_EMY"],
    ["OKJ", "Oakland", "us-Amtrak_OKJ"],
    ["ORL", "Orlando", "us-Amtrak_ORL"],
    ["MIA", "Miami Amtrak Station", "us-Amtrak_MIA"],
    ["TPA", "Tampa", "us-Amtrak_TPA"],
    ["STL", "St Louis", "us-Amtrak_STL"],
    ["KCY", "Kansas City", "us-Amtrak_KCY"],
    ["New Orleans", "New Orleans Union Passenger Terminal", "us-Amtrak_NOL"],
    ["NOL", "New Orleans Union Passenger Terminal", "us-Amtrak_NOL"],
  ] as const)("normalizes %s to the intended intercity hub", (query, searchValue, preferredNativeId) => {
    expect(transitousSearchAlias(query)).toEqual({ searchValue, preferredNativeId });
  });

  it("ranks the intended station first when two cities share the same name", async () => {
    const payload = [
      {
        type: "PLACE", name: "Portland", id: "node/[186579]", lat: 45.5202, lon: -122.6742,
        country: "US", tz: "America/Los_Angeles", category: "place_6",
      },
      {
        type: "STOP", name: "Portland", id: "us-Amtrak_PDX", lat: 45.528725, lon: -122.6768,
        country: "US", tz: "America/Los_Angeles", modes: ["REGIONAL_RAIL"],
      },
      {
        type: "PLACE", name: "Portland", id: "node/[158998527]", lat: 43.6591, lon: -70.2568,
        country: "US", tz: "America/New_York", category: "place_6",
      },
      {
        type: "STOP", name: "Portland", id: "us-Amtrak_POR", lat: 43.6541, lon: -70.29126,
        country: "US", tz: "America/New_York", modes: ["REGIONAL_RAIL"],
      },
    ];

    const { places, request } = await searchPayload("Portland, Maine", payload);

    expect(request?.searchParams.get("text")).toBe("Portland");
    expect(decodeRailPlaceId(places[0]!.id).nativeId).toBe("us-Amtrak_POR");
  });
});
