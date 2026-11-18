import { expect, it } from "vitest";
import { StaticGTFSProvider } from "../src/providers/mainline-gtfs-provider.js";
import { compileMainlineGTFS } from "../src/providers/mainline-gtfs-compiler.js";
import { GTFSDiscoveryProvider, GTFSJourneyProvider } from "../src/providers/mainline-gtfs-routing.js";
import { taiwanArchive } from "../worker-tests/fixtures/taiwan-gtfs.js";
import { ProviderRegistry } from "../src/providers/provider.js";
import { JourneySearchService } from "../src/services/journey-search-service.js";

it("routes a new-country place through signed journey resolution and a refreshable snapshot", async () => {
  const now = () => new Date("2026-11-14T00:00:00Z");
  const index = await compileMainlineGTFS(taiwanArchive(), { country: "TW", now: now() });
  const taiwan = new StaticGTFSProvider("TW", async () => index, { now });
  const upstream = { source: "transitous" as const, discoveryScope: "international" as const,
    async searchStations() { throw new Error("upstream unavailable"); }, async fetchBoard() { throw new Error("wrong board route"); },
    async fetchTrip() { throw new Error("wrong trip route"); } };
  const rail = new GTFSDiscoveryProvider(upstream,[taiwan]);
  expect(await rail.searchStations("Taipei")).toHaveLength(2);
  const journey = new GTFSJourneyProvider({ async searchPlaces() { throw new Error("upstream unavailable"); }, async searchJourneys() { throw new Error("wrong journey route"); } }, [taiwan]);
  const service = new JourneySearchService(journey,new ProviderRegistry([rail]), "gtfs-journey-test-signing-secret-at-least-32-characters", { log() {} }, undefined, now);
  const from = (await service.searchPlaces("臺北",10,"test"))[0]!;
  const to = (await service.searchPlaces("花蓮",10,"test"))[0]!;
  const page = await service.searchJourneys({ originId: from.id, destinationId: to.id, time: "2026-11-14T15:00:00Z", arriveBy: false, maxTransfers: 0, cursor: null },"test");
  const resolution = await service.resolvePlan([page.options[0]!.trackingToken],"test");
  expect(resolution.directions[0]!.segments[0]!.failure).toBeNull();
  const trip = resolution.directions[0]!.segments[0]!.trip!;
  expect(trip.stops[0]!.stationId).toBe("eu:transitous:ttgtfs:TW:stop:TRA_1000");
  expect(trip.stops.at(-1)!.stationId).toBe("eu:transitous:ttgtfs:TW:stop:TRA_7000");
  expect(resolution.directions[0]!.segments[0]!.coverage.features.delays.support).toBe("notProvided");
  expect((await rail.fetchTrip(trip)).id).toBe(trip.id);
});

it("suppresses upstream Taiwan discovery that could re-admit Alishan outside the agency allowlist",async () => {
  const index=await compileMainlineGTFS(taiwanArchive(),{country:"TW",now:new Date("2026-11-14T00:00:00Z")});
  const taiwan=new StaticGTFSProvider("TW",async()=>index);
  const upstream={source:"transitous" as const,discoveryScope:"international" as const,
    async searchStations(){return [
      {id:"eu:transitous:tw-taiwan-tdx_AFR",source:"transitous" as const,nativeId:"tw-taiwan-tdx_AFR",name:"Alishan",countryCode:"TW",latitude:23.5,longitude:120.8,operatorHints:["AFR"]},
      {id:"eu:transitous:fr-paris",source:"transitous" as const,nativeId:"fr-paris",name:"Paris",countryCode:"FR",latitude:48.8,longitude:2.3,operatorHints:["SNCF"]},
    ];},async fetchBoard(){return [];},async fetchTrip(){throw new Error("unused");}};
  expect((await new GTFSDiscoveryProvider(upstream,[taiwan]).searchStations("Alishan")).map(s=>s.countryCode)).toEqual(["FR"]);
});
