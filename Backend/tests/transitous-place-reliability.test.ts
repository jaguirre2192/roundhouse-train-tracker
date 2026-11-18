import { describe, expect, it } from "vitest";
import { TransitousJourneyProvider } from "../src/providers/transitous-journeys.js";
import { decodeRailPlaceId } from "../src/providers/rail-place-id.js";

function station(name: string, id: string, country: string, modes = ["LONG_DISTANCE"]) {
  const locations: Record<string, { lat: number; lon: number; tz: string }> = {
    DE: { lat: 52.525, lon: 13.369, tz: "Europe/Berlin" },
    AT: { lat: 48.185, lon: 16.378, tz: "Europe/Vienna" },
    PT: { lat: 38.76777, lon: -9.09914, tz: "Europe/Lisbon" },
    FR: { lat: 49.0097, lon: 2.5486, tz: "Europe/Paris" },
    US: { lat: 40.7505, lon: -73.9934, tz: "America/New_York" },
  };
  return { type: "STOP", name, id, country, modes, ...locations[country] };
}

describe("place search preserves valid upstream railway matches", () => {
  it("resolves a ticket's full New York Penn name through the upstream accepted spelling", async () => {
    const provider = new TransitousJourneyProvider("https://provider.test", async (url) => {
      const query = new URL(String(url)).searchParams.get("text");
      return Response.json(query === "New York Penn" ? [
        station("NEW YORK PENN STATION", "us-Amtrak_NYP", "US"),
        station("NEWARK PENN STATION", "us-Amtrak_NWK", "US"),
      ] : []);
    });
    const places = await provider.searchPlaces("NEW YORK PENN STATION", 5);
    expect(places.map((p) => decodeRailPlaceId(p.id).nativeId)).toEqual(["us-Amtrak_NYP"]);
  });

  it("matches Hauptbahnhof to Hbf without accepting another city's station", async () => {
    const provider = new TransitousJourneyProvider("https://provider.test", async () => Response.json([
      station("Berlin Hbf", "de-DELFI_berlin", "DE"),
      station("Wien Hauptbahnhof", "at-oebb_wien", "AT"),
    ]));
    expect((await provider.searchPlaces("Berlin Hauptbahnhof", 5)).map((p) => p.displayName))
      .toEqual(["Berlin Hbf"]);
  });

  it("accepts an EU feed's railway interchange using the station country", async () => {
    const provider = new TransitousJourneyProvider("https://provider.test", async () => Response.json([
      station("Lisboa Oriente", "eu-blablacar-bus_ALE", "PT", ["COACH", "REGIONAL_RAIL", "SUBURBAN"]),
      station("Lisboa Oriente Coach", "eu-blablacar-bus_coach", "PT", ["COACH"]),
    ]));
    const places = await provider.searchPlaces("Lisboa Oriente", 5);
    expect(places).toHaveLength(1);
    expect(decodeRailPlaceId(places[0]!.id)).toMatchObject({ nativeId: "pt-Comboios-de-Portugal(CP)_94_31039", countryCode: "PT" });
  });

  it("resolves the explicit CDG Terminal 2 name without accepting an airport-only place", async () => {
    const provider = new TransitousJourneyProvider("https://provider.test", async () => Response.json([
      station("Aéroport Charles-de-Gaulle TGV", "fr-horaires-sncf_CDG2", "FR", ["HIGHSPEED_RAIL"]),
      { type: "PLACE", name: "Aéroport Charles de Gaulle 2 TGV", id: "way/airport", country: "FR", category: "aerodrome", lat: 49.0, lon: 2.57 },
    ]));
    expect((await provider.searchPlaces("Aéroport Charles de Gaulle 2 TGV", 5)).map((p) => p.displayName))
      .toEqual(["Aéroport Charles-de-Gaulle TGV"]);
  });

  it("keeps excluded country feeds and urban-only stations out of an EU interchange search", async () => {
    const provider = new TransitousJourneyProvider("https://provider.test", async () => Response.json([
      station("Oriente", "eu-interchange_rail", "PT", ["REGIONAL_RAIL"]),
      station("Oriente", "eu-interchange_urban", "PT", ["SUBURBAN", "SUBWAY"]),
      station("Oriente", "tw-mainline_station", "PT", ["HIGHSPEED_RAIL"]),
    ]));
    expect((await provider.searchPlaces("Oriente", 5)).map((p) => decodeRailPlaceId(p.id).nativeId))
      .toEqual(["eu-interchange_rail"]);
  });
});
