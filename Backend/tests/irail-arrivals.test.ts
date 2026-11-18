import { describe, expect, it } from "vitest";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { IRailPlatformOverlay } from "../src/providers/irail.js";

const snapshot: TripSnapshot = {
  id: "be-arrival", source: "transitous", nativeId: "be-IC3240", serviceDate: "2026-11-13",
  operatorName: "SNCB", product: "IC 3240", headsign: "Brussels-South", fetchedAt: "2026-11-13T17:40:00Z", alertIds: [],
  stops: [{
    stationId: "BE.NMBS.008814001", stationName: "Brussels-South", countryCode: "BE", latitude: 50.836, longitude: 4.336,
    sequence: 1, scheduledArrival: "2026-11-13T17:43:00Z", scheduledDeparture: null,
    expectedArrival: "2026-11-13T17:43:00Z", expectedDeparture: null,
    plannedPlatform: null, expectedPlatform: null, platformSource: null, platformObservedAt: null, cancelled: false, passed: false,
  }],
};
const movement = {
  time: String(Date.parse("2026-11-13T17:43:00Z") / 1000), delay: "180", canceled: "1",
  vehicle: "BE.NMBS.IC3240", vehicleinfo: { shortname: "IC 3240", number: "3240" }, platform: "9",
};

describe("iRail terminal arrivals", () => {
  it("requests the arrival board and maps arrival time, platform, and cancellation", async () => {
    const urls: URL[] = [];
    const overlay = new IRailPlatformOverlay("https://example.test/v1", async (input) => {
      urls.push(new URL(String(input)));
      return Response.json({ timestamp: String(Date.parse(snapshot.fetchedAt) / 1000), arrivals: { arrival: [movement] } });
    });
    const [first, second] = await Promise.all([overlay.platformUpdates(snapshot), overlay.platformUpdates(snapshot)]);
    expect(first).toEqual(second);
    expect(urls).toHaveLength(1);
    expect(urls[0]?.searchParams.get("arrdep")).toBe("arrival");
    expect(first[0]).toMatchObject({ expectedArrival: "2026-11-13T17:46:00.000Z", expectedDeparture: undefined, expectedPlatform: "9", cancelled: true });
  });

  it("never substitutes departure-board data for a terminal arrival", async () => {
    const overlay = new IRailPlatformOverlay("https://example.test/v1", async () =>
      Response.json({ timestamp: "1794591600", departures: { departure: [movement] } }));
    expect(await overlay.platformUpdates(snapshot)).toEqual([]);
  });

  it("rejects arrivals of a different numbered service", async () => {
    const overlay = new IRailPlatformOverlay("https://example.test/v1", async () =>
      Response.json({ timestamp: "1794591600", arrivals: { arrival: [{ ...movement, vehicle: "BE.NMBS.IC3241", vehicleinfo: { number: "3241" } }] } }));
    expect(await overlay.platformUpdates(snapshot)).toEqual([]);
  });
});
