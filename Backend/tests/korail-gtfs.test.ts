import { describe, expect, it } from "vitest";
import { transit_realtime } from "gtfs-realtime-bindings";
import { compileMainlineGTFS } from "../src/providers/mainline-gtfs-compiler.js";
import { StaticGTFSProvider } from "../src/providers/mainline-gtfs-provider.js";
import { KorailRealtime } from "../src/providers/korail-realtime.js";
import { korailArchive } from "../worker-tests/fixtures/korail-gtfs.js";
import { diffSnapshots } from "../src/domain/events.js";
import { defaultPushPreferences } from "../src/domain/snapshot.js";
import { JourneySearchService } from "../src/services/journey-search-service.js";
import { ProviderRegistry } from "../src/providers/provider.js";

const now = () => new Date("2026-11-14T15:31:00Z");
function feed(seconds = 180, options: { publishedAt?: string; startDate?: string; duplicate?: boolean } = {}) {
  const trip = { tripId: "1", ...(options.startDate ? { startDate: options.startDate } : {}) };
  const update = { id: "trip_update_1", tripUpdate: { trip, delay: seconds, stopTimeUpdate: [{ stopSequence: 0, departure: { delay: seconds } }] } };
  return transit_realtime.FeedMessage.encode({ header: { gtfsRealtimeVersion: "2.0", timestamp: Date.parse(options.publishedAt ?? "2026-11-14T15:30:00Z")/1000 }, entity: [
    update, ...(options.duplicate ? [{ ...update, id: "duplicate" }] : []),
    { id: "position_1", vehicle: { trip, position: { latitude: 36.5, longitude: 127.5 } } },
  ] }).finish();
}
async function setup(bytes = feed(), compiledAt = new Date("2026-11-01T00:00:00Z")) {
  const index = await compileMainlineGTFS(korailArchive(),{ country: "KR", now: compiledAt });
  const realtime = new KorailRealtime(async () => new Response(new Uint8Array(bytes).buffer),now);
  const provider = new StaticGTFSProvider("KR",async () => index,{ now, realtime: (snapshot,index,trip) => realtime.enrich(snapshot,index,trip) });
  const station = (await provider.searchStations("Seoul"))[0]!;
  const board = await provider.fetchBoard({ source: station.source, stationId: station.id, nativeId: station.nativeId, at: "2026-11-14T14:00:00Z", direction: "departures" });
  return { index, provider, trip: board.find(entry => entry.product === "KTX 1")!.trip };
}
describe("Korail schedule and whole-trip realtime honesty",() => {
  it("retains raw trip IDs and English station translations despite old-but-valid static data",async () => {
    const {index,provider,trip} = await setup();
    expect(index.trips.map(t=>t.id).sort()).toEqual(["1","2"]);
    expect((await provider.searchStations("서울"))[0]!.countryCode).toBe("KR");
    const snapshot = await provider.fetchTrip(trip);
    expect(snapshot.product).toBe("KTX 1");
    expect(snapshot.stops[0]!.scheduledDeparture).toBe("2026-11-14T14:50:00.000Z");
    expect(snapshot.stops[1]!.scheduledArrival).toBe("2026-11-14T17:10:00.000Z");
  });
  it("keeps delay scoped to the whole trip, withholding stop-zero estimates and undated coordinates",async () => {
    const {provider,trip} = await setup();
    const snapshot = await provider.fetchTrip(trip);
    expect(snapshot.tripLevelDelay).toMatchObject({ seconds: 180, scope: "whole-trip", feedPublishedAt: "2026-11-14T15:30:00.000Z" });
    expect(snapshot.positions).toBeUndefined();
    expect(snapshot.stops.every(s=>s.expectedDeparture===null && s.expectedArrival===null && s.expectedPlatform===null && s.plannedPlatform===null && !s.cancelled && !s.passed)).toBe(true);
    expect(snapshot.alertIds).toEqual([]);
  });
  it("does not turn a changed whole-trip delay into a per-stop watcher event",async () => {
    const a=await setup(feed(60)),b=await setup(feed(900));
    const before=await a.provider.fetchTrip(a.trip),after=await b.provider.fetchTrip(b.trip);
    expect(before.tripLevelDelay?.seconds).toBe(60);expect(after.tripLevelDelay?.seconds).toBe(900);
    expect(diffSnapshots(before,after,defaultPushPreferences)).toEqual([]);
  });
  it.each([
    { publishedAt: "2026-11-14T15:20:00Z" },
    { startDate: "20261115" },
    { duplicate: true },
  ])("withholds stale, wrong-date or ambiguous realtime: %j",async options => {
    const {provider,trip}=await setup(feed(180,options));
    expect((await provider.fetchTrip(trip)).tripLevelDelay).toBeUndefined();
  });
  it("does not attach today's undated realtime to a future repetition of the same train",async () => {
    const {provider,trip}=await setup();
    const future={ ...trip, serviceDate: "2026-11-15", nativeId: trip.nativeId.replace("2026-11-14","2026-11-15"), id: trip.id.replace("2026-11-14","2026-11-15") };
    expect((await provider.fetchTrip(future)).tripLevelDelay).toBeUndefined();
  });
  it("preserves schedule access during a realtime outage",async () => {
    const index=await compileMainlineGTFS(korailArchive(),{ country:"KR",now:now() });
    const realtime=new KorailRealtime(async()=>{throw new Error("provider offline");},now);
    const provider=new StaticGTFSProvider("KR",async()=>index,{now,realtime:(s,i,t)=>realtime.enrich(s,i,t)});
    const station=(await provider.searchStations("Seoul"))[0]!;
    const board=await provider.fetchBoard({source:station.source,stationId:station.id,nativeId:station.nativeId,direction:"departures",at:"2026-11-14T14:00:00Z"});
    expect((await provider.fetchTrip(board[0]!.trip)).stops).toHaveLength(2);
  });
  it("resolves a signed Seoul-Busan journey with per-stop coverage kept separate from whole-trip delay",async () => {
    const {provider}=await setup();
    const service=new JourneySearchService(provider,new ProviderRegistry([provider]),"korail-test-signing-secret-at-least-32-characters",{log(){}},undefined,now);
    const from=(await service.searchPlaces("Seoul",5,"test"))[0]!,to=(await service.searchPlaces("Busan",5,"test"))[0]!;
    const page=await service.searchJourneys({originId:from.id,destinationId:to.id,time:"2026-11-14T14:00:00Z",arriveBy:false,maxTransfers:0,cursor:null},"test");
    expect(page.options[0]!.segments[0]!.rail?.isRealtime).toBe(false);
    const resolution=await service.resolvePlan([page.options[0]!.trackingToken],"test");
    const segment=resolution.directions[0]!.segments[0]!;
    expect(segment.failure).toBeNull();
    expect(segment.trip?.stops[0]!.stationId).toBe("eu:transitous:ttgtfs:KR:stop:seoul");
    expect(segment.coverage.features.delays.support).toBe("notProvided");
    expect(segment.trip?.tripLevelDelay?.scope).toBe("whole-trip");
  });
});
