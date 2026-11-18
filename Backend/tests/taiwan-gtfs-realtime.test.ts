import { describe, expect, it, vi } from "vitest";
import type { CanonicalTripReference, TripSnapshot } from "../src/domain/snapshot.js";
import { compileMainlineGTFS } from "../src/providers/mainline-gtfs-compiler.js";
import { StaticGTFSProvider } from "../src/providers/mainline-gtfs-provider.js";
import { ProviderRegistry } from "../src/providers/provider.js";
import { enrichTaiwanMirrorBoard, enrichTaiwanMirrorTrip } from "../src/providers/taiwan-gtfs-realtime.js";
import { tdxTraSource } from "../src/providers/tdx-live.js";
import { JourneySearchService } from "../src/services/journey-search-service.js";
import { assessTripCoverage } from "../src/services/trip-coverage-assessment.js";
import { taiwanArchive } from "../worker-tests/fixtures/taiwan-gtfs.js";

const clock = () => new Date("2026-11-14T16:00:00Z"); // Already November 15 in Taipei.
const recorded = "2026-11-14T15:59:30Z";
const config = { enabledSources: new Set(["tdx"]) };
const index = compileMainlineGTFS(taiwanArchive(), { country: "TW", now: clock() });
const baseline = new StaticGTFSProvider("TW", () => index, { now: clock });
const id = "ttgtfs:TW:trip:2026-11-14:TRA_101@85800";
const saved: CanonicalTripReference = { id: `eu:transitous:${id}`, source: "transitous", nativeId: id, serviceDate: "2026-11-14" };
const official: CanonicalTripReference = { id: "tw:tdx:TRA:101", source: "tdx", nativeId: "TRA:101", serviceDate: saved.serviceDate };

async function officialSnapshot(): Promise<TripSnapshot> {
  const mirror = await baseline.fetchTrip(saved);
  const [origin, destination] = mirror.stops;
  return {
    ...mirror, ...official, operatorName: "Taiwan Railway Corporation", product: "Tze-Chiang Express 101",
    tripLevelDelay: { source: tdxTraSource, scope: "whole-trip", seconds: 0, feedPublishedAt: recorded },
    stops: [
      { ...origin!, stationId: "tw:tdx:TRA:1000", passed: true, passageObservedAt: recorded },
      { ...destination!, stationId: "tw:tdx:TRA:7000", expectedArrival: "2026-11-14T18:16:00.000Z",
        expectedArrivalEvidence: { source: tdxTraSource, observedAt: recorded },
        expectedPlatform: "2A", platformSource: tdxTraSource, platformObservedAt: recorded },
    ],
  };
}

describe("Taiwan indexed booking and TDX observations", () => {
  it("preserves the signed journey, midnight service date, boarding IDs and original per-feature times", async () => {
    const fetchOfficial = vi.fn(async () => officialSnapshot());
    const provider = new StaticGTFSProvider("TW", () => index, {
      now: clock, realtime: snapshot => enrichTaiwanMirrorTrip(snapshot, fetchOfficial, clock()),
    });
    const service = new JourneySearchService(provider, new ProviderRegistry([provider]), "taiwan-signing-secret-longer-than-32-characters",
      { log() {} }, undefined, clock, config);
    const [from] = await service.searchPlaces("臺北", 5, "taiwan");
    const [to] = await service.searchPlaces("花蓮", 5, "taiwan");
    const page = await service.searchJourneys({
      originId: from!.id, destinationId: to!.id, time: "2026-11-14T15:45:00Z",
      arriveBy: false, maxTransfers: 0, cursor: null,
    }, "taiwan");
    expect(page.options[0]!.segments[0]!.rail?.isRealtime).toBe(false);
    expect(fetchOfficial).not.toHaveBeenCalled();
    const plan = await service.resolvePlan([page.options[0]!.trackingToken], "taiwan");
    const segment = plan.directions[0]!.segments[0]!;
    expect(segment.failure).toBeNull();
    expect(fetchOfficial).toHaveBeenCalledWith(official);
    expect(segment.trip).toMatchObject({
      ...saved, tripLevelDelay: { seconds: 0, feedPublishedAt: recorded },
      stops: [
        { stationId: "eu:transitous:ttgtfs:TW:stop:TRA_1000", stationName: "臺北", expectedDeparture: null, passageObservedAt: recorded },
        { stationId: "eu:transitous:ttgtfs:TW:stop:TRA_7000", stationName: "花蓮", scheduledArrival: "2026-11-14T18:10:00.000Z",
          expectedArrival: "2026-11-14T18:16:00.000Z", expectedPlatform: "2A", platformObservedAt: recorded },
      ],
    });
    expect(segment.coverage.sourceIds).toEqual(["transitous", "tdx-mirror", "tdx"]);
    expect(segment.coverage.features).toMatchObject({
      delays: { availability: "observed", observedAt: recorded }, platforms: { availability: "observed", observedAt: recorded },
      position: { support: "notProvided", availability: "notObserved" }, cancellations: { availability: "notObserved" },
    });
  });

  it("rejects a wrong service day, operator, repeated run, inconsistent stop order or different scheduled call", async () => {
    const mirror = await baseline.fetchTrip(saved), trip = await officialSnapshot();
    const wrongTrips = [
      { ...trip, serviceDate: "2026-11-15" },
      { ...trip, nativeId: "THSR:101", id: "tw:tdx:THSR:101" },
      { ...trip, nativeId: "TRA:110", id: "tw:tdx:TRA:110" },
      { ...trip, stops: [...trip.stops].reverse() },
      { ...trip, stops: trip.stops.map((s, i) => i ? { ...s, scheduledArrival: "2026-11-15T18:10:00.000Z" } : s) },
    ];
    for (const wrong of wrongTrips) {
      expect(await enrichTaiwanMirrorTrip(mirror, async () => wrong, clock())).toBe(mirror);
    }
    expect(await enrichTaiwanMirrorTrip(mirror, async () => { throw Error("Free request allowance exhausted"); }, clock())).toBe(mirror);
    const skip = vi.fn(async () => trip);
    expect(await enrichTaiwanMirrorTrip(mirror, skip, new Date("2026-11-13T16:00:00Z"))).toBe(mirror);
    const otherSystem = { ...mirror, nativeId: mirror.nativeId.replace("TRA_", "THSR_") };
    expect(await enrichTaiwanMirrorTrip(otherSystem, skip, clock())).toBe(otherSystem);
    expect(skip).not.toHaveBeenCalled();
  });

  it("withholds stale, undated, or unrelated reports across a fresh fetch, including cancellations and station passage", async () => {
    const mirror = await baseline.fetchTrip(saved), trip = await officialSnapshot();
    trip.stops[0]!.cancelled = true; // A schedule suspension supplies no live cancellation timestamp.
    trip.stops[1]!.expectedArrivalEvidence!.source = "Another railway";
    trip.stops[1]!.arrivalObservedAt = "2026-11-14T16:15:00Z";
    const later = new Date("2026-11-14T16:10:00Z");
    const result = await enrichTaiwanMirrorTrip(mirror, async () => trip, later);
    expect(result).toEqual(mirror);
    const coverage = assessTripCoverage({ ...trip, fetchedAt: later.toISOString() }, config, later);
    expect(Object.values(coverage.features).every(f => f.availability === "notObserved")).toBe(true);
  });

  it("reports a train-wide zero and a positive station cancellation without creating stop forecasts or a GPS point", async () => {
    const mirror = await baseline.fetchTrip(saved), trip = await officialSnapshot();
    trip.stops = trip.stops.map(s => ({
      ...s, expectedArrival: null, expectedPlatform: null, cancelled: true, cancellationObservedAt: recorded,
    }));
    const result = await enrichTaiwanMirrorTrip(mirror, async () => trip, clock());
    expect(result.positions).toBeUndefined();
    expect(result.stops.every(s => s.cancelled && !s.expectedArrival && !s.expectedDeparture && !s.passed)).toBe(true);
    const coverage = assessTripCoverage(result, config, clock());
    expect(coverage.features.delays).toEqual({ support: "connected", availability: "observed", observedAt: recorded });
    expect(coverage.features.cancellations).toEqual({ support: "connected", availability: "observed", observedAt: recorded });
    expect(coverage.features.platforms.availability).toBe("notObserved");
    expect(assessTripCoverage(mirror, undefined, clock()).limitationCodes).toEqual(["timetableOnly"]);
  });

  it("retains a delayed, already-due train on the board under its original trackable ID", async () => {
    const tdx = await officialSnapshot();
    const report = { trip: official, stop: { ...tdx.stops[0]!, expectedDeparture: "2026-11-14T16:05:00Z",
      expectedDepartureEvidence: { source: tdxTraSource, observedAt: recorded } }, product: tdx.product, headsign: tdx.headsign };
    const fetchBoard = vi.fn(async () => [report]);
    const provider = new StaticGTFSProvider("TW", () => index, {
      now: clock, realtimeBoard: (entries, station) => enrichTaiwanMirrorBoard(entries, station, fetchBoard, clock()),
    });
    const [station] = await provider.searchStations("臺北");
    const reference = { source: station!.source, stationId: station!.id, nativeId: station!.nativeId, at: clock().toISOString(),
      direction: "departures" as const };
    const entries = await provider.fetchBoard(reference);
    expect(fetchBoard).toHaveBeenCalledWith({ ...reference, source: "tdx", nativeId: "TRA:1000", stationId: "tw:tdx:TRA:1000" });
    expect(entries[0]).toMatchObject({ trip: saved, stop: { expectedDeparture: "2026-11-14T16:05:00Z" } });
    expect((await baseline.fetchBoard(reference)).some(row => row.trip.id === saved.id)).toBe(false);
    fetchBoard.mockResolvedValueOnce([report, report]);
    expect(await provider.fetchBoard(reference)).toEqual(await baseline.fetchBoard(reference));
  });

  it("spends no official requests on THSR autocomplete, boards or trips and retains direct-provider bookmarks", async () => {
    const tdx = { source: "tdx" as const, discoveryScope: "international" as const, searchStations: vi.fn(),
      fetchTrip: vi.fn(async () => officialSnapshot()), fetchBoard: vi.fn(async () => []) };
    const provider = new StaticGTFSProvider("TW", () => index, {
      now: clock, realtime: snapshot => enrichTaiwanMirrorTrip(snapshot, tdx.fetchTrip, clock()),
      realtimeBoard: (entries, station) => enrichTaiwanMirrorBoard(entries, station, tdx.fetchBoard, clock()),
    });
    const registry = new ProviderRegistry([tdx, provider], undefined, undefined, [provider]);
    const stations = await registry.searchStations("international", "Taipei");
    expect(stations).toHaveLength(2);
    expect(tdx.searchStations).not.toHaveBeenCalled();
    const station = stations.find(s => s.nativeId.endsWith("THSR_1000"))!;
    const [entry] = await registry.fetchBoard({ source: station.source, stationId: station.id, nativeId: station.nativeId,
      at: "2026-11-14T00:00:00Z", direction: "departures" });
    const trip = await registry.fetchTrip(entry!.trip);
    expect(assessTripCoverage(trip, config, clock()).features.delays.support).toBe("notProvided");
    expect(tdx.fetchBoard).not.toHaveBeenCalled();
    expect(tdx.fetchTrip).not.toHaveBeenCalled();
    expect((await registry.fetchTrip(official)).id).toBe(official.id);
  });
});
