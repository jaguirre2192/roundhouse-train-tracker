import { describe, it, expect } from "vitest";
import { TransitousProvider } from "../src/providers/transitous.js";

const nativeId = "20261119_08:01_fr-eurostar-gtfs-plan-de-transport-et-temps-reel_9004-1119";
const savedDeparture = "2026-11-19T07:01:00Z";
const savedArrival = "2026-11-19T09:21:00Z";
// Station zones, departure and arrival from Transitous's Nov 19 2026 Eurostar 9004.
async function eurostar(fromZone?: string, toZone?: string) {
  const leg = {
    mode: "HIGHSPEED_RAIL", tripId: nativeId, tripShortName: "9004", agencyName: "Eurostar",
    from: { stopId: "STP", name: "St-Pancras-International", lat: 51.5322, lon: -0.1261, tz: fromZone, scheduledDeparture: savedDeparture },
    to: { stopId: "PNO", name: "Paris-Nord", lat: 48.8809, lon: 2.3553, tz: toZone, scheduledArrival: savedArrival },
  };
  const provider = new TransitousProvider("https://provider.test", async () => Response.json({ legs: [leg] }));
  return provider.fetchTrip({ id: "eurostar:9004", source: "transitous", nativeId, serviceDate: "2026-11-19" });
}

describe("station clocks reported on Transitous calls", () => {
  it("preserves both local zones and absolute instants on the refreshed Eurostar trip", async () => {
    const [london, paris] = (await eurostar("Europe/London", "Europe/Paris")).stops;
    expect(london).toMatchObject({ timeZoneIdentifier: "Europe/London", scheduledDeparture: savedDeparture });
    expect(paris).toMatchObject({ timeZoneIdentifier: "Europe/Paris", scheduledArrival: savedArrival });
  });
  it.each([undefined, "No/SuchZone", "Etc/UTC", "UTC", "GMT+3"])("does not invent a local station zone for %s", async (unknown) => {
    const [london, paris] = (await eurostar(unknown, "Europe/Paris")).stops;
    expect(london).not.toHaveProperty("timeZoneIdentifier");
    expect(paris?.timeZoneIdentifier).toBe("Europe/Paris");
  });
});
