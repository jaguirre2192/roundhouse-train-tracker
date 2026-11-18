import { describe, expect, it } from "vitest";
import type { StopSnapshot, TripSnapshot } from "../src/domain/snapshot.js";
import { hasReportedArrival, hasReportedPassage } from "../src/domain/stop-passage.js";
import { shouldRetireTripWatch } from "../src/domain/trip-watch-recovery.js";
import { AmtrakerVehiclePositionOverlay } from "../src/providers/amtraker-vehicle-position.js";
import type { AmtrakerTrain } from "../src/providers/amtraker.js";
import { TripSnapshotEnricher, type PlatformObservation } from "../src/providers/platform-overlay.js";

const now = "2026-11-13T12:00:00.000Z";
function train(): AmtrakerTrain {
  return { trainID: "171-13", trainNum: "171", routeName: "Northeast Regional", updatedAt: now,
    lastValTS: now, lat: 40.75, lon: -73.99, stations: [
      { code: "WAS", name: "Washington Union", schDep: "2026-11-13T09:00:00Z", dep: "2026-11-13T09:15:00Z", status: "Departed" },
      { code: "PHL", name: "Philadelphia 30th Street", schArr: "2026-11-13T10:00:00Z", schDep: "2026-11-13T10:02:00Z",
        arr: "2026-11-13T10:45:00Z", dep: "2026-11-13T10:50:00Z", status: "Departed" },
      { code: "NYP", name: "New York Penn", schArr: "2026-11-13T11:00:00Z", arr: "2026-11-13T11:45:00Z", status: "Arrived" },
    ] };
}
function snapshot(): TripSnapshot {
  return { id: "us:transitous:us-Amtrak-import", source: "transitous", nativeId: "us-Amtrak-import",
    serviceDate: "2026-11-13", operatorName: "Amtrak", product: "Northeast Regional 171", headsign: "New York Penn",
    fetchedAt: now, alertIds: [], stops: train().stations.map((stop, index): StopSnapshot => ({
      stationId: `us:transitous:us-Amtrak_${stop.code}`, stationName: stop.name, sequence: index + 1, countryCode: "US",
      latitude: [38.897, 39.95, 40.75][index]!, longitude: [-77.006, -75.18, -73.99][index]!,
      scheduledArrival: stop.schArr ?? null, scheduledDeparture: stop.schDep ?? null,
      expectedArrival: stop.schArr ?? null, expectedDeparture: stop.schDep ?? null,
      plannedPlatform: null, expectedPlatform: null, platformSource: null, platformObservedAt: null, cancelled: false, passed: false,
    })) };
}
function provider(trains: AmtrakerTrain[], clock = () => new Date(now), requests: string[] = []) {
  return new AmtrakerVehiclePositionOverlay("https://example.test", async (input) => {
    requests.push(String(input));
    return Response.json({ "171": trains });
  }, clock);
}

describe("imported Amtrak observation enrichment", () => {
  it("enriches delayed intermediate stops and explicit terminal arrival using one fetch for timing and GPS", async () => {
    const requests: string[] = [];
    const overlay = provider([train()], undefined, requests);
    const result = await new TripSnapshotEnricher([overlay], [overlay]).enrich(snapshot());
    expect(requests).toEqual(["https://example.test/trains/171"]);
    expect(result.id).toBe(snapshot().id);
    expect(result.positions).toHaveLength(1);
    expect(result.stops[1]).toMatchObject({ expectedArrival: "2026-11-13T10:45:00.000Z",
      expectedDeparture: "2026-11-13T10:50:00.000Z", passed: true, passageObservedAt: "2026-11-13T10:50:00.000Z" });
    expect(result.stops[2]).toMatchObject({ expectedArrival: "2026-11-13T11:45:00.000Z",
      passed: false, arrivalObservedAt: "2026-11-13T11:45:00.000Z" });
    expect(hasReportedPassage(result.stops[1]!, now)).toBe(true);
    expect(hasReportedArrival(result.stops[2]!, now)).toBe(true);
    expect(shouldRetireTripWatch(result, Date.parse("2026-11-13T14:00:00Z"))).toBe(true);
  });

  it("preserves source event timestamps across repeated polls and works without GPS", async () => {
    let clock = new Date(now);
    const value = { ...train(), lat: null, lon: null };
    const overlay = provider([value], () => clock);
    const enricher = new TripSnapshotEnricher([overlay], [overlay]);
    const first = await enricher.enrich(snapshot());
    clock = new Date("2026-11-13T12:10:00Z");
    const second = await enricher.enrich({ ...snapshot(), fetchedAt: clock.toISOString() });
    expect(first.positions).toBeUndefined();
    expect(first.stops).toEqual(second.stops);
    expect(hasReportedArrival(second.stops[2]!, clock.toISOString())).toBe(true);
  });

  it("rejects wrong-day, cross-number, and multiple matching train instances", async () => {
    const tomorrow = train();
    tomorrow.stations = tomorrow.stations.map((stop) => ({ ...stop,
      ...(stop.schArr ? { schArr: stop.schArr.replace("-13T", "-14T") } : {}),
      ...(stop.schDep ? { schDep: stop.schDep.replace("-13T", "-14T") } : {}),
    }));
    for (const candidates of [[tomorrow], [{ ...train(), trainNum: "172" }], [train(), { ...train(), trainID: "171-other" }]]) {
      const overlay = provider(candidates);
      expect(await overlay.platformUpdates(snapshot())).toEqual([]);
      expect(await overlay.positionUpdates(snapshot())).toEqual([]);
    }
  });

  it("rejects unrelated or ambiguous repeated calls without transferring their times or evidence", async () => {
    const value = train();
    value.stations.push({ ...value.stations[1]! });
    value.stations[2] = { ...value.stations[2]!, code: "BOS", name: "Boston South" };
    const result = await new TripSnapshotEnricher([provider([value])]).enrich(snapshot());
    expect(result.stops[0]!.passed).toBe(true);
    expect(result.stops[1]).toEqual(snapshot().stops[1]);
    expect(result.stops[2]).toEqual(snapshot().stops[2]);
    const repeated = snapshot();
    repeated.stops.push({ ...repeated.stops[0]!, sequence: 4 });
    const observations = await provider([train()]).platformUpdates(repeated);
    expect(observations.some((value) => value.stationId === repeated.stops[0]!.stationId)).toBe(false);
  });

  it("matches scheduled like events within90 seconds, never arrival against departure", async () => {
    const value = snapshot();
    value.stops = [value.stops[0]!];
    value.stops[0]!.scheduledDeparture = "2026-11-13T09:01:30Z";
    expect(await provider([train()]).platformUpdates(value)).toHaveLength(1);
    value.stops[0]!.scheduledDeparture = "2026-11-13T09:01:31Z";
    expect(await provider([train()]).platformUpdates(value)).toEqual([]);
    value.stops[0]!.scheduledDeparture = null;
    value.stops[0]!.scheduledArrival = "2026-11-13T09:00:00Z";
    expect(await provider([train()]).platformUpdates(value)).toEqual([]);
  });

  it("shares an in-flight fetch and rejects unstamped, mismatched or future passage observations", async () => {
    const requests: string[] = [];
    const overlay = provider([train()], undefined, requests);
    await Promise.all([overlay.platformUpdates(snapshot()), overlay.positionUpdates(snapshot())]);
    expect(requests).toHaveLength(1);
    const base = snapshot();
    const observation: PlatformObservation = { stopSequence: 1, stationId: base.stops[0]!.stationId,
      observedAt: now, source: "Amtraker", passed: true };
    for (const value of [observation, { ...observation, passageObservedAt: "invalid" },
      { ...observation, passageObservedAt: "2026-11-13T12:02:01Z" },
      { ...observation, stationId: "another-station", passageObservedAt: now }]) {
      const result = await new TripSnapshotEnricher([{ sourceName: "Amtraker", supportedCountryCodes: new Set(["US"]),
        platformUpdates: async () => [value] }]).enrich(base);
      expect(hasReportedPassage(result.stops[0]!, now)).toBe(false);
    }
  });
});
