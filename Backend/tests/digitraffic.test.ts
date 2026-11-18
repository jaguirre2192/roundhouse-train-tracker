import { describe, expect, it } from "vitest";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { TripSnapshotEnricher } from "../src/providers/platform-overlay.js";
import { DigitrafficPlatformOverlay } from "../src/providers/digitraffic.js";
import { digitrafficPosition } from "../src/providers/digitraffic-position.js";

const now = new Date("2026-11-13T17:40:00Z");
const trip = (): TripSnapshot => ({
  id: "eu:transitous:fi-10", source: "transitous", nativeId: "fi-10", serviceDate: "2026-11-13",
  operatorName: "VR", product: "IC 10", headsign: "Helsinki", fetchedAt: now.toISOString(), alertIds: [],
  stops: [{
    stationId: "fi-TKL", stationName: "Tikkurila", countryCode: "FI", latitude: 60.292, longitude: 25.044,
    sequence: 4, scheduledArrival: "2026-11-13T17:30:00Z", scheduledDeparture: "2026-11-13T17:31:00Z",
    expectedArrival: "2026-11-13T17:30:00Z", expectedDeparture: "2026-11-13T17:31:00Z",
    plannedPlatform: "1", expectedPlatform: "1", platformSource: null, platformObservedAt: null,
    cancelled: false, passed: false,
  }],
});
const train = () => ({
  trainNumber: 10, departureDate: "2026-11-13", commuterLineID: "",
  timeTableRows: [
    { stationShortCode: "TKL", type: "ARRIVAL", scheduledTime: "2026-11-13T17:30:00Z", actualTime: "2026-11-13T17:35:19Z", commercialTrack: "1", cancelled: false },
    { stationShortCode: "TKL", type: "DEPARTURE", scheduledTime: "2026-11-13T17:31:00Z", actualTime: "2026-11-13T17:36:53Z", commercialTrack: "1", cancelled: false },
  ],
});
const location = () => ({
  trainNumber: 10, departureDate: "2026-11-13", timestamp: "2026-11-13T17:39:50Z", isGpsLocation: true,
  location: { type: "Point", coordinates: [25.04, 60.28] },
});
function provider(trains = [train()]) {
  const paths: string[] = [];
  const overlay = new DigitrafficPlatformOverlay("https://example.test", async (input) => {
    const path = new URL(String(input)).pathname;
    paths.push(path);
    if (path.includes("metadata")) return Response.json([{ passengerTraffic: true, stationName: "Tikkurila", stationShortCode: "TKL" }]);
    if (path.includes("train-locations")) return Response.json([location()]);
    return Response.json(trains);
  }, () => now);
  return { overlay, paths };
}

describe("Digitraffic realtime enrichment", () => {
  it("preserves both reported station events and joins the same dated train's GPS position", async () => {
    const { overlay, paths } = provider();
    const result = await new TripSnapshotEnricher([overlay], [overlay]).enrich(trip());
    expect(result.stops[0]).toMatchObject({
      expectedArrival: "2026-11-13T17:35:19.000Z", expectedDeparture: "2026-11-13T17:36:53.000Z",
      arrivalObservedAt: "2026-11-13T17:35:19.000Z", passageObservedAt: "2026-11-13T17:36:53.000Z", passed: true,
    });
    expect(result.positions?.[0]).toMatchObject({ latitude: 60.28, longitude: 25.04, source: "real", asOf: "2026-11-13T17:39:50.000Z" });
    expect(paths.filter((path) => path.includes("live-trains"))).toHaveLength(1);
  });

  it("shares simultaneous enrichment loads and preserves forecasts without claiming passage", async () => {
    const forecast = train();
    const { actualTime: _arrival, ...arrival } = forecast.timeTableRows[0]!;
    const { actualTime: _departure, ...departure } = forecast.timeTableRows[1]!;
    const paths: string[] = [];
    const overlay = new DigitrafficPlatformOverlay("https://example.test", async (input) => {
      const path = new URL(String(input)).pathname; paths.push(path);
      return path.includes("metadata")
        ? Response.json([{ passengerTraffic: true, stationName: "Tikkurila", stationShortCode: "TKL" }])
        : Response.json([{ ...forecast, timeTableRows: [
          { ...arrival, liveEstimateTime: "2026-11-13T17:45:00Z" },
          { ...departure, liveEstimateTime: "2026-11-13T17:46:00Z" },
        ] }]);
    }, () => now);
    const [first, second] = await Promise.all([overlay.platformUpdates(trip()), overlay.platformUpdates(trip())]);
    expect(first).toEqual(second);
    expect(first[0]).toMatchObject({ expectedArrival: "2026-11-13T17:45:00.000Z", expectedDeparture: "2026-11-13T17:46:00.000Z" });
    expect(first[0]?.passageObservedAt).toBeUndefined();
    expect(first[0]?.arrivalObservedAt).toBeUndefined();
    expect(paths).toHaveLength(2);
  });

  it.each(["different date", "different run", "ambiguous run"])("fails closed for %s", async (kind) => {
    const wrong = train();
    if (kind === "different date") wrong.departureDate = "2026-11-12";
    if (kind === "different run") wrong.timeTableRows = wrong.timeTableRows.map((row) => ({ ...row, scheduledTime: "2026-11-13T18:30:00Z" }));
    const { overlay, paths } = provider(kind === "ambiguous run" ? [wrong, train()] : [wrong]);
    expect(await overlay.platformUpdates(trip())).toEqual([]);
    expect(await overlay.positionUpdates(trip())).toEqual([]);
    expect(paths.some((path) => path.includes("train-locations"))).toBe(false);
  });

  it("enriches the terminal beyond the bounded request anchors from the full identified train", async () => {
    const snapshot = trip();
    const full = train();
    for (const [index, code] of ["A", "B", "C"].entries()) {
      const scheduled = `2026-11-13T18:${String(index * 10).padStart(2, "0")}:00Z`;
      snapshot.stops.push({ ...snapshot.stops[0]!, stationId: `fi-${code}`, stationName: code, sequence: index + 5,
        scheduledArrival: scheduled, scheduledDeparture: code === "C" ? null : scheduled,
        expectedArrival: scheduled, expectedDeparture: code === "C" ? null : scheduled });
      full.timeTableRows.push({ stationShortCode: code, type: "ARRIVAL", scheduledTime: scheduled,
        actualTime: "", commercialTrack: "9", cancelled: false });
      Object.assign(full.timeTableRows.at(-1)!, { liveEstimateTime: scheduled.replace(":00Z", ":30Z") });
      if (code !== "C") full.timeTableRows.push({ stationShortCode: code, type: "DEPARTURE", scheduledTime: scheduled,
        actualTime: "", commercialTrack: "9", cancelled: false });
    }
    const requests: string[] = [];
    const overlay = new DigitrafficPlatformOverlay("https://example.test", async (input) => {
      const path = new URL(String(input)).pathname; requests.push(path);
      if (path.includes("metadata")) return Response.json(["TKL", "A", "B", "C"].map((code) => ({
        passengerTraffic: true, stationName: code === "TKL" ? "Tikkurila" : code, stationShortCode: code,
      })));
      return Response.json([full]);
    }, () => now);
    const result = await overlay.platformUpdates(snapshot);
    expect(requests.some((path) => path.endsWith("/C"))).toBe(false);
    expect(result).toContainEqual(expect.objectContaining({ stationId: "fi-C", expectedArrival: "2026-11-13T18:20:30.000Z", expectedPlatform: "9" }));
  });

  it("does not replace an explicit train number with another run on the same commuter line", async () => {
    const other = { ...train(), trainNumber: 999, commuterLineID: "IC" };
    expect(await provider([other]).overlay.platformUpdates(trip())).toEqual([]);
  });
});

describe("Digitraffic vehicle evidence", () => {
  it.each(["date", "number", "stale", "future", "coordinate", "approximate", "duplicate"])("rejects %s position evidence", (kind) => {
    const value = location();
    if (kind === "date") value.departureDate = "2026-11-12";
    if (kind === "number") value.trainNumber = 11;
    if (kind === "stale") value.timestamp = "2026-11-13T17:00:00Z";
    if (kind === "future") value.timestamp = "2026-11-13T18:00:00Z";
    if (kind === "coordinate") value.location.coordinates = [181, 60];
    if (kind === "approximate") value.isGpsLocation = false;
    expect(digitrafficPosition(train(), kind === "duplicate" ? [value, value] : [value], now, "Fintraffic Digitraffic")).toEqual([]);
  });
});
