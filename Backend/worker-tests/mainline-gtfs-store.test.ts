import { env, runInDurableObject, SELF } from "cloudflare:test";
import { expect, it, vi } from "vitest";
import type { WorkerEnv } from "../src/cloudflare/env.js";
import { GTFSRailIndexStore } from "../src/cloudflare/mainline-gtfs-store.js";
import { compileMainlineGTFS } from "../src/providers/mainline-gtfs-compiler.js";
import { taiwanArchive } from "./fixtures/taiwan-gtfs.js";
import { handleRailDataRefresh } from "../src/cloudflare/rail-data-refresh-route.js";
import type { BoardEntrySnapshot, StationSnapshot } from "../src/domain/discovery.js";
import { createWatcherServices } from "../src/cloudflare/watcher-services.js";
import { TdxProvider } from "../src/providers/tdx.js";
import { StaticGTFSProvider } from "../src/providers/mainline-gtfs-provider.js";
import { tdxTraSource } from "../src/providers/tdx-live.js";

it("atomically retains a verified timetable across restarts, malformed refreshes and replayed older feeds", async () => {
  const index = await compileMainlineGTFS(taiwanArchive(), { country: "TW", now: new Date("2026-11-14T00:00:00Z") });
  const stub = (env as unknown as WorkerEnv).WATCHER.getByName("gtfs-index-store-test");
  await runInDurableObject(stub,async (_instance,state) => {
    const store = new GTFSRailIndexStore(state.storage,"TW");
    expect(await store.save(index)).toMatchObject({ outcome: "stored" });
    expect(await new GTFSRailIndexStore(state.storage,"TW").load()).toEqual(index);
    expect(await store.save({ ...index, trips: [] })).toMatchObject({ outcome: "invalid" });
    expect(await store.save({ ...index, compiledAt: "2026-11-13T00:00:00Z" })).toMatchObject({ outcome: "older" });
    expect(await store.load()).toEqual(index);
    expect(await store.save({ ...index, compiledAt: "2026-11-14T00:01:00Z" })).toMatchObject({ outcome: "unchanged" });
    expect(await new GTFSRailIndexStore(state.storage,"TW").health()).toMatchObject({ country: "TW", stations: 4, trips: 2 });
  });
});

it("publishes through the authenticated boundary and serves Taiwan through the production station/board/trip routes",async () => {
  vi.useFakeTimers({ toFake: ["Date"] }); vi.setSystemTime(new Date("2026-11-14T00:00:00Z"));
  const fetcher = vi.spyOn(globalThis,"fetch").mockResolvedValue(Response.json([]));
  try {
    const bindings = env as unknown as WorkerEnv;
    const index = await compileMainlineGTFS(taiwanArchive(),{ country: "TW" });
    const secret = "mainline-worker-test-secret-32-characters";
    const request = new Request("https://api.test/internal/rail-data/mainline-gtfs/tw",{ method: "POST", headers: {
      authorization: `Bearer ${secret}`, "content-type": "application/json",
    },body: JSON.stringify(index) });
    const published = await handleRailDataRefresh(request as Parameters<typeof handleRailDataRefresh>[0],{ ...bindings, RAIL_DATA_REFRESH_SECRET: secret },bindings.WATCHER.getByName("global"),"/internal/rail-data/mainline-gtfs/tw");
    expect(published?.status).toBe(200);
    const stations = await (await SELF.fetch("https://api.test/v1/stations/search?scope=international&query=Taipei")).json() as StationSnapshot[];
    const station = stations.find(s => s.nativeId.endsWith("TRA_1000"))!;
    expect(station.countryCode).toBe("TW");
    const boardQuery = new URLSearchParams({ ...station, source: station.source, at: "2026-11-14T15:00:00Z", direction: "departures", stationId: station.id } as unknown as Record<string,string>);
    const boardResponse = await SELF.fetch(`https://api.test/v1/stations/board?${boardQuery}`);
    expect(boardResponse.status).toBe(200);
    const board = await boardResponse.json() as BoardEntrySnapshot[];
    const tripQuery = new URLSearchParams({ ...board[0]!.trip });
    const tripResponse = await SELF.fetch(`https://api.test/v1/trips/snapshot?${tripQuery}`);
    expect(tripResponse.status).toBe(200);
    expect(await tripResponse.json()).toMatchObject({ product: "TRA 101", stops: [
      { stationName: "臺北", scheduledDeparture: "2026-11-14T15:50:00.000Z", expectedDeparture: null, plannedPlatform: null },
      { stationName: "花蓮", scheduledArrival: "2026-11-14T18:10:00.000Z", expectedArrival: null, plannedPlatform: null },
    ] });
  } finally { fetcher.mockRestore(); vi.useRealTimers(); }
});

it("uses the same approved TDX provider for a stored TRA journey and excludes it from worldwide autocomplete", async () => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(new Date("2026-11-14T16:00:00Z"));
  const clock = new Date().toISOString();
  const index = await compileMainlineGTFS(taiwanArchive(), { country: "TW" });
  const mirror = new StaticGTFSProvider("TW", async () => index);
  const nativeId = "ttgtfs:TW:trip:2026-11-14:TRA_101@85800";
  const saved = { source: "transitous" as const, nativeId, id: `eu:transitous:${nativeId}`, serviceDate: "2026-11-14" };
  const scheduled = await mirror.fetchTrip(saved);
  const tdxTrip = vi.spyOn(TdxProvider.prototype, "fetchTrip").mockImplementation(async reference => ({
    ...scheduled, ...reference, tripLevelDelay: { seconds: 240, scope: "whole-trip", feedPublishedAt: clock, source: tdxTraSource },
    stops: scheduled.stops.map(s => ({ ...s, stationId: s.stationId.replace("eu:transitous:ttgtfs:TW:stop:TRA_", "tw:tdx:TRA:") })),
  }));
  const officialSearch = vi.spyOn(TdxProvider.prototype, "searchStations");
  vi.spyOn(globalThis, "fetch").mockImplementation(async () => { throw Error("External traffic disabled in this test"); });
  try {
    const bindings = env as unknown as WorkerEnv;
    await runInDurableObject(bindings.WATCHER.getByName("taiwan-credentialed-tracking-test"), async (_instance, state) => {
      await new GTFSRailIndexStore(state.storage, "TW").save(index);
      const services = createWatcherServices(state, { ...bindings, TDX_CLIENT_ID: "fixture-id", TDX_CLIENT_SECRET: "fixture-secret" });
      const places = await services.providers.searchStations("international", "Taipei");
      expect(places.map(p => p.nativeId)).toEqual(expect.arrayContaining(["ttgtfs:TW:stop:TRA_1000", "ttgtfs:TW:stop:THSR_1000"]));
      expect(officialSearch).not.toHaveBeenCalled();
      const sameTrip = await services.providers.fetchTrip(saved);
      expect(tdxTrip).toHaveBeenCalledWith({ id: "tw:tdx:TRA:101", nativeId: "TRA:101", source: "tdx", serviceDate: saved.serviceDate },
        { includeStationCoordinates: false });
      expect(sameTrip).toMatchObject({ ...saved, tripLevelDelay: { seconds: 240 }, stops: scheduled.stops });
    });
  } finally { vi.restoreAllMocks(); vi.useRealTimers(); }
});
