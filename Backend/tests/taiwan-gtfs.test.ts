import { describe, expect, it } from "vitest";
import { taiwanArchive } from "../worker-tests/fixtures/taiwan-gtfs.js";
import { compileMainlineGTFS, compileMainlineGTFSPhases } from "../src/providers/mainline-gtfs-compiler.js";
import { StaticGTFSProvider } from "../src/providers/mainline-gtfs-provider.js";

const now = () => new Date("2026-11-14T00:00:00Z");
const compile = (overrides: Record<string, string> = {}) => compileMainlineGTFS(taiwanArchive(overrides), { country: "TW", now: now() });

describe("Taiwan mirror schedule coverage", () => {
  it("allowlists TRA/THSR before considering rail mode and discards fares", async () => {
    const index = await compile();
    expect(index.trips).toHaveLength(2);
    expect(index.trips.map(t => t.agency).sort()).toEqual(["THSR", "TRA"]);
    expect(index.stations.map(s => s.id).sort()).toEqual(["THSR_1000", "THSR_1070", "TRA_1000", "TRA_7000"]);
    expect(JSON.stringify(index)).not.toContain("fare_products");
  });

  it("compacts date-expanded identical schedules without assuming stop_times order", async () => {
    const index = await compile();
    const tra = index.trips.find(t => t.agency === "TRA")!;
    expect(index.services[tra.service]).toEqual(["2026-11-14", "2026-11-15"]);
    expect(tra.calls.map(c => c[1])).toEqual([1, 2]);
    expect(tra.calls[1]![2]).toBe(26 * 3600 + 10 * 60);
  });

  it("searches English and Chinese station names and returns schedule-only boards/trips", async () => {
    const index = await compile();
    const provider = new StaticGTFSProvider("TW", async () => index, { now });
    const stations = await provider.searchStations("Taipei");
    expect(stations).toHaveLength(2);
    expect(await provider.searchStations("臺北")).toHaveLength(1);
    const station = stations.find(s => s.nativeId.endsWith("TRA_1000"))!;
    const board = await provider.fetchBoard({ stationId: station.id, nativeId: station.nativeId, source: "transitous", direction: "departures", at: "2026-11-14T15:00:00Z" });
    expect(board).toHaveLength(1);
    const trip = await provider.fetchTrip(board[0]!.trip);
    expect(trip.stops[0]!.scheduledDeparture).toBe("2026-11-14T15:50:00.000Z");
    expect(trip.stops[1]!.scheduledArrival).toBe("2026-11-14T18:10:00.000Z");
    expect(trip.stops.every(s => s.expectedArrival === null && s.expectedDeparture === null && s.plannedPlatform === null && s.expectedPlatform === null && !s.cancelled && !s.passed)).toBe(true);
    expect(trip.alertIds).toEqual([]);
    expect(trip.positions).toBeUndefined();
    await expect(provider.fetchTrip({ ...board[0]!.trip, serviceDate: "2026-11-16" })).rejects.toThrow();
  });

  it("honors calendar removals and rejects forged trip identity", async () => {
    const provider = new StaticGTFSProvider("TW", async () => await compile(), { now });
    const station = (await provider.searchStations("Taipei")).find(s => s.nativeId.endsWith("THSR_1000"))!;
    const reference = { stationId: station.id, nativeId: station.nativeId, source: "transitous" as const, direction: "departures" as const, at: "2026-11-14T00:00:00Z" };
    const board = await provider.fetchBoard(reference);
    expect(board).toHaveLength(1);
    expect(await provider.fetchBoard({ ...reference, at: "2026-11-15T00:00:00Z" })).toEqual([]);
    await expect(provider.fetchTrip({ ...board[0]!.trip, id: "forged" })).rejects.toThrow();
  });

  it("rejects incomplete or nonchronological selected services instead of publishing partial data", async () => {
    await expect(compile({ "stop_times.txt": "trip_id,arrival_time,departure_time,stop_id,stop_sequence\ntra-day1,12:00:00,12:00:00,TRA_1000,1\ntra-day1,11:00:00,11:00:00,TRA_7000,2\n" })).rejects.toThrow();
    await expect(compile({ "routes.txt": "route_id,agency_id,route_type\nAFR_1,AFR,2\n" })).rejects.toThrow();
  });

  it("exposes a direct journey using the same scheduled station/trip identity", async () => {
    const provider = new StaticGTFSProvider("TW", async () => await compile(), { now });
    const from = (await provider.searchPlaces("臺北", 10))[0]!;
    const to = (await provider.searchPlaces("花蓮", 10))[0]!;
    const page = await provider.searchJourneys({ originId: from.id, destinationId: to.id, time: "2026-11-14T15:00:00Z", arriveBy: false, maxTransfers: 0, providerCursor: null });
    expect(page.options).toHaveLength(2);
    expect(page.options[0]!.segments[0]!.rail).toMatchObject({ isRealtime: false, isTrackable: true, serviceDate: "2026-11-14" });
    expect(page.attributions.join(" ")).toContain("Ministry of Transportation and Communications Transportation Data Circulation Service Platform");
  });
  it("keeps service calendars distinct across the 32-day and 64-day boundaries",async () => {
    const provider = new StaticGTFSProvider("TW",async () => await compile(),{ now });
    const station = (await provider.searchStations("Taipei")).find(s => s.nativeId.endsWith("THSR_1000"))!;
    const input = { stationId: station.id, nativeId: station.nativeId, source: station.source, direction: "departures" as const, at: "2026-12-20T00:00:00Z" };
    expect(await provider.fetchBoard(input)).toHaveLength(1);
    await expect(provider.fetchBoard({ ...input, at: "2027-01-20T00:00:00Z" })).rejects.toThrow("outside the published timetable");
  });
  it("suspends between archive, fingerprint and final passes for bounded Worker requests",async () => {
    const work = compileMainlineGTFSPhases(taiwanArchive(),{ country: "TW", now: now() });
    expect(await work.next()).toMatchObject({ done: false, value: { phase: "archive-loaded" } });
    expect(await work.next()).toMatchObject({ done: false, value: { phase: "calls-fingerprinted" } });
    expect(await work.next()).toMatchObject({ done: true, value: { country: "TW", trips: expect.any(Array) } });
  });
});
