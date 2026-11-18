import { describe, expect, it } from "vitest";
import { normalizeJourneyOptions } from "../src/providers/journey-normalizer.js";
import { journeyMainlinePolicy } from "../src/providers/journey-mainline-policy.js";
import type { TransitousLeg } from "../src/providers/transitous-journey-types.js";

// Public Transitous response captured 2026-11-12 for the Hunter Line. Keep the
// feed's generic railway type and platform/parent identities exactly as returned.
function hunterLeg(): TransitousLeg {
  const feed = "au-nsw-Transport-for-New-South-Wales-nsw-trains_";
  return {
    mode: "REGIONAL_RAIL", routeType: 100,
    tripId: "20261113_11:29_" + feed + "V737.131126.16.J.2.1129",
    routeShortName: "HUN", routeLongName: "Hunter Line", tripShortName: "V737",
    agencyName: "Intercity Train", realTime: true,
    startTime: "2026-11-13T00:29:00Z", endTime: "2026-11-13T01:00:00Z", duration: 1860,
    from: {
      name: "Newcastle Interchange", stopId: feed + "229352", parentId: feed + "229310",
      lat: -32.923958, lon: 151.75902, tz: "Australia/Sydney",
      scheduledDeparture: "2026-11-13T00:29:00Z", departure: "2026-11-13T00:29:00Z",
      scheduledTrack: "2", track: "2", cancelled: false,
    },
    to: {
      name: "Maitland Station", stopId: feed + "2320312", parentId: feed + "232020",
      lat: -32.73792, lon: 151.55194, tz: "Australia/Sydney",
      scheduledArrival: "2026-11-13T01:00:00Z", arrival: "2026-11-13T01:00:00Z",
      scheduledTrack: "2", track: "2", cancelled: false,
    },
  };
}

describe("generic GTFS railway services", () => {
  it("retains the real Hunter Line service through journey normalization", () => {
    const leg = hunterLeg();
    const options = normalizeJourneyOptions({ itineraries: [{
      startTime: leg.startTime, endTime: leg.endTime, duration: 1860, transfers: 0, legs: [leg],
    }] }, {
      originKind: "station", destinationKind: "station",
      fetchedAt: "2026-11-12T23:45:00Z", attributions: ["Transitous"],
    });
    expect(options).toHaveLength(1);
    expect(options[0]?.segments[0]).toMatchObject({ kind: "rail", rail: {
      trainNumber: "V737", serviceDate: "2026-11-13", isTrackable: true,
      from: { place: { displayName: "Newcastle Interchange", countryCode: "AU" }, scheduledDeparture: leg.startTime },
      to: { place: { displayName: "Maitland Station", countryCode: "AU" }, scheduledArrival: leg.endTime },
    } });
    expect(options[0]?.transferCount).toBe(0);
  });

  it.each(["SUBURBAN", "METRO", "TRAM", "BUS"])("still rejects %s carrying a generic railway type", (mode) => {
    expect(journeyMainlinePolicy.classify({ ...hunterLeg(), mode })).toBe("prohibited");
  });

  it("still rejects unsupported urban feeds and stations", () => {
    const urbanTrip = { ...hunterLeg(), tripId: "20261113_11:29_au-nsw-sydney-trains_T1" };
    expect(journeyMainlinePolicy.classify(urbanTrip)).toBe("prohibited");
    const urbanStation = hunterLeg();
    urbanStation.from.stopId = "au-nsw-sydney-trains_200060";
    expect(journeyMainlinePolicy.classify(urbanStation)).toBe("prohibited");
  });

  it("still rejects an explicitly suburban railway category despite a regional mode", () => {
    expect(journeyMainlinePolicy.classify({ ...hunterLeg(), routeType: 109 })).toBe("prohibited");
  });
});
