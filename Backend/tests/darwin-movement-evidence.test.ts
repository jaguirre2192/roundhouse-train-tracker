import { describe, expect, it } from "vitest";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { DarwinRealtimeOverlay, parseDarwinDocument } from "../src/providers/darwin-realtime.js";
import { TripSnapshotEnricher } from "../src/providers/platform-overlay.js";

const day = "2026-11-13", uid = "G12345";
const snapshot: TripSnapshot = {
  id: "eu:transitous:20261113_12:00_gb-great-britain_G12345_20261113",
  source: "transitous", nativeId: "20261113_12:00_gb-great-britain_G12345_20261113",
  serviceDate: day, operatorName: "GWR", product: "GWR", headsign: "Reading",
  fetchedAt: "2026-11-13T12:40:00Z", alertIds: [],
  stops: [{ stationId: "eu:transitous:gb-great-britain_9100RDNGSTN12", stationName: "Reading",
    countryCode: "GB", latitude: 51.459, longitude: -0.972, sequence: 1,
    scheduledArrival: "2026-11-13T12:25:00Z", scheduledDeparture: "2026-11-13T12:27:00Z",
    expectedArrival: "2026-11-13T12:25:00Z", expectedDeparture: "2026-11-13T12:27:00Z",
    plannedPlatform: "12", expectedPlatform: "12", platformSource: null, platformObservedAt: null,
    cancelled: false, passed: false }],
};

function document(movement: string) {
  return `<Pport ts="2026-11-13T12:39:00Z"><uR><TS uid="${uid}" ssd="${day}">
    <ns5:Location tpl="RDNGSTN">${movement}</ns5:Location></TS></uR></Pport>`;
}

async function enrich(xml: string, trip = snapshot) {
  const state = parseDarwinDocument(xml, uid, day);
  return new TripSnapshotEnricher([new DarwinRealtimeOverlay({ latestTrip: async () => state })]).enrich(trip);
}

describe("Darwin actual movement evidence", () => {
  it("keeps distinct reported arrival and departure timestamps", async () => {
    const value = await enrich(document('<ns5:arr at="12:30:12"/><ns5:dep at="12:32:45"/>'));
    expect(value.stops[0]).toMatchObject({ passed: true,
      expectedArrival: "2026-11-13T12:30:12.000Z", expectedDeparture: "2026-11-13T12:32:45.000Z",
      arrivalObservedAt: "2026-11-13T12:30:12.000Z", passageObservedAt: "2026-11-13T12:32:45.000Z" });
  });

  it("reports arrival without claiming departure", async () => {
    const value = await enrich(document('<ns5:arr at="12:30:12"/><ns5:dep et="12:45"/>'));
    expect(value.stops[0]?.arrivalObservedAt).toBe("2026-11-13T12:30:12.000Z");
    expect(value.stops[0]?.passageObservedAt).toBeUndefined();
    expect(value.stops[0]?.passed).toBe(false);
  });

  it("never upgrades elapsed forecasts into actual events", async () => {
    const value = await enrich(document('<ns5:arr et="12:30"/><ns5:dep wet="12:32"/>'));
    expect(value.stops[0]?.arrivalObservedAt).toBeUndefined();
    expect(value.stops[0]?.passageObservedAt).toBeUndefined();
    expect(value.stops[0]?.passed).toBe(false);
  });

  it("preserves an actual across unrelated patches and removes it only on explicit retraction", async () => {
    let state = parseDarwinDocument(document('<ns5:arr at="12:30"/><ns5:dep at="12:32"/>'), uid, day);
    state = parseDarwinDocument(document('<ns5:plat>9</ns5:plat>'), uid, day, state);
    expect(state?.locations.get("RDNGSTN")?.actualDeparture).toBe("12:32");
    state = parseDarwinDocument(document('<ns5:arr atRemoved="true" et="12:43"/><ns5:dep atRemoved="true" et="12:45"/>'), uid, day, state);
    expect(state?.locations.get("RDNGSTN")).toMatchObject({ expectedArrival: "12:43", expectedDeparture: "12:45" });
    const value = await new TripSnapshotEnricher([new DarwinRealtimeOverlay({ latestTrip: async () => state })]).enrich(snapshot);
    expect(value.stops[0]?.arrivalObservedAt).toBeUndefined();
    expect(value.stops[0]?.passageObservedAt).toBeUndefined();
    expect(value.stops[0]?.passed).toBe(false);
  });

  it("rejects future actuals and ambiguous repeated station visits", async () => {
    const future = await enrich(document('<ns5:arr at="13:30"/><ns5:dep at="13:32"/>'));
    expect(future.stops[0]?.arrivalObservedAt).toBeUndefined();
    expect(future.stops[0]?.passageObservedAt).toBeUndefined();
    const repeated = await enrich(document('<ns5:dep at="12:32"/>'), {
      ...snapshot, stops: [snapshot.stops[0]!, { ...snapshot.stops[0]!, sequence: 2 }],
    });
    expect(repeated.stops.every((stop) => !stop.passed && stop.passageObservedAt === undefined)).toBe(true);
  });

  it("accepts an explicit pass event without manufacturing an arrival", async () => {
    const value = await enrich(document('<ns5:pass at="12:32:45"/>'));
    expect(value.stops[0]?.passageObservedAt).toBe("2026-11-13T12:32:45.000Z");
    expect(value.stops[0]?.arrivalObservedAt).toBeUndefined();
    expect(value.stops[0]?.passed).toBe(true);
  });
});
