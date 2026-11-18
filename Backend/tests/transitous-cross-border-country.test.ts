import { describe, expect, it, vi } from "vitest";
import { normalizeJourneyOptions } from "../src/providers/journey-normalizer.js";
import { decodeRailPlaceId } from "../src/providers/rail-place-id.js";
import { TransitousProvider } from "../src/providers/transitous.js";
import { physicalCountryCode } from "../src/providers/country-location.js";
import { MobiliteitLuRealtimeOverlay } from "../src/providers/mobiliteit-lu.js";
import { TripSnapshotEnricher } from "../src/providers/platform-overlay.js";
import type { TransitousJourneyPlace } from "../src/providers/transitous-journey-types.js";

const tripId = "20261113_08:23_nl-OpenOV_394267965";
const now = new Date("2026-11-12T23:31:00Z");
// Station coordinates and opaque OpenOV IDs from the live NS International trip.
const calls: TransitousJourneyPlace[] = [
  { name: "Paris-Nord", stopId: "nl-OpenOV_2993634", lat: 48.881737, lon: 2.3559237, tz: "Europe/Paris" },
  { name: "Brussel-Zuid", stopId: "nl-OpenOV_2992416", lat: 50.835217, lon: 4.3354797, tz: "Europe/Brussels" },
  { name: "Antwerpen-Centraal", stopId: "nl-OpenOV_2992247", lat: 51.216022, lon: 4.421053, tz: "Europe/Brussels" },
  { name: "Rotterdam Centraal", stopId: "nl-OpenOV_2993757", lat: 51.92536, lon: 4.4683733, tz: "Europe/Brussels" },
  { name: "Amsterdam Centraal", stopId: "nl-OpenOV_2992198", lat: 52.37863, lon: 4.9014134, tz: "Europe/Brussels" },
];

function payload(stops = calls) {
  const leg = {
    mode: "HIGHSPEED_RAIL", routeType: 101, tripId, tripShortName: "9315", agencyName: "NS International",
    startTime: "2026-11-13T07:23:00Z", endTime: "2026-11-13T10:50:00Z", duration: 12420,
    from: { ...stops[0]!, scheduledDeparture: "2026-11-13T07:23:00Z" },
    to: { ...stops.at(-1)!, scheduledArrival: "2026-11-13T10:50:00Z" },
    intermediateStops: stops.slice(1, -1),
  };
  return { legs: [leg], itineraries: [{ startTime: leg.startTime, endTime: leg.endTime, duration: leg.duration, transfers: 0, legs: [leg] }] };
}

function normalizedCalls(stops = calls) {
  const [option] = normalizeJourneyOptions(payload(stops), {
    originKind: "station", destinationKind: "station", fetchedAt: now.toISOString(), attributions: ["Transitous"],
  });
  const segment = option?.segments[0];
  if (segment?.kind !== "rail") throw new Error("Expected cross-border railway option");
  return [segment.rail.from, ...segment.rail.intermediateCalls, segment.rail.to];
}

async function snapshot(stops = calls) {
  const provider = new TransitousProvider("https://provider.test", async () => Response.json(payload(stops)), () => now);
  return provider.fetchTrip({ id: `eu:transitous:${tripId}`, source: "transitous", nativeId: tripId, serviceDate: "2026-11-13" });
}

describe("cross-border physical station countries", () => {
  it("encodes each journey call's physical country rather than its Dutch feed prefix or inherited timezone", () => {
    const places = normalizedCalls().map((call) => call.place);
    expect(places.map((place) => place.countryCode)).toEqual(["FR", "BE", "BE", "NL", "NL"]);
    expect(places.map((place) => decodeRailPlaceId(place.id).countryCode)).toEqual(["FR", "BE", "BE", "NL", "NL"]);
    expect(places.map((place) => decodeRailPlaceId(place.id).nativeId)).toEqual(calls.map((call) => call.stopId));
  });

  it("uses identical country metadata in planned calls and refreshed snapshot stops", async () => {
    const trip = await snapshot();
    expect(trip.stops.map((stop) => stop.countryCode)).toEqual(["FR", "BE", "BE", "NL", "NL"]);
    expect(trip.stops.map((stop) => stop.countryCode)).toEqual(normalizedCalls().map((call) => call.place.countryCode));
    expect(trip.stops.map((stop) => stop.stationId)).toEqual(calls.map((call) => `eu:transitous:${call.stopId}`));
  });

  it("honors explicit station country metadata", async () => {
    const zurich = { name: "Zürich HB", stopId: "nl-foreign-zurich", lat: 47.378, lon: 8.54, country: "CH" };
    const stops = [calls[0]!, zurich];
    expect(normalizedCalls(stops).at(-1)!.place.countryCode).toBe("CH");
    expect((await snapshot(stops)).stops.at(-1)!.countryCode).toBe("CH");
  });

  it("corrects Lille and Amsterdam while preserving neighboring-country and invalid coordinates", () => {
    expect(physicalCountryCode("NL", 50.636, 3.069)).toBe("FR");
    expect(physicalCountryCode("FR", 52.37863, 4.9014134)).toBe("NL");
    for (const [country, lat, lon] of [
      ["LU", 49.6116, 6.1319], ["DE", 50.767, 6.091], ["CH", 47.547, 7.59], ["IT", 43.791, 7.608],
    ] as const) expect(physicalCountryCode(country, lat, lon)).toBe(country);
    expect(physicalCountryCode("DE", Number.NaN, 4.3)).toBe("DE");
  });
});

// Reproduced board/planner station identities from the 2026-11-13 inventory.
// Expected values include foreign stops: a route's seed country is not its stops' country.
const inventoryStations = [
  {"name": "Baku", "stopId": "ge-georgian-railway_baku", "lat": 40.38078, "lon": 49.850628, "expectedCountry": "AZ"},
  {"name": "Gardabani", "stopId": "ge-georgian-railway_gardabani", "lat": 41.47544, "lon": 45.098026, "expectedCountry": "GE"},
  {"name": "Budapest-Keleti", "stopId": "at-Railway-Current-Reference-Data-2026_hu:14216:27001535:27001419", "lat": 47.50042, "lon": 19.084618, "expectedCountry": "HU"},
  {"name": "Győr", "stopId": "at-Railway-Current-Reference-Data-2026_hu:28007:51761:0:27000407", "lat": 47.682175, "lon": 17.635555, "expectedCountry": "HU"},
  {"name": "Wien Hauptbahnhof", "stopId": "at-Railway-Current-Reference-Data-2026_at:49:1349:0:27", "lat": 48.18487, "lon": 16.378452, "expectedCountry": "AT"},
  {"name": "Freilassing Bahnhof", "stopId": "at-Railway-Current-Reference-Data-2026_de:09172:42293:3:4", "lat": 47.836937, "lon": 12.97655, "expectedCountry": "DE"},
  {"name": "Feldkirch", "stopId": "ch-opentransportdataswiss26_8101236_gen:missingSLOID_pf:1", "lat": 47.24098, "lon": 9.604104, "expectedCountry": "AT"},
  {"name": "Nendeln", "stopId": "ch-opentransportdataswiss26_8101242_gen:missingSLOID_pf:2", "lat": 47.200203, "lon": 9.541627, "expectedCountry": "LI"},
  {"name": "Forst (FL) Hilti", "stopId": "ch-opentransportdataswiss26_8101237_gen:missingSLOID_pf:1", "lat": 47.18091, "lon": 9.520704, "expectedCountry": "LI"},
  {"name": "Schaan-Vaduz", "stopId": "ch-opentransportdataswiss26_8101243_gen:missingSLOID_pf:1", "lat": 47.168293, "lon": 9.507796, "expectedCountry": "LI"},
  {"name": "Buchs SG", "stopId": "ch-opentransportdataswiss26_ch:1:sloid:9404:3:3", "lat": 47.169727, "lon": 9.478511, "expectedCountry": "CH"},
  {"name": "Buchs Bahnhof", "stopId": "at-Railway-Current-Reference-Data-2026_ch:23016:20302:0:2", "lat": 47.169014, "lon": 9.478519, "expectedCountry": "CH"},
  {"name": "Sargans Bahnhof", "stopId": "at-Railway-Current-Reference-Data-2026_ch:23016:20329:0:2", "lat": 47.04515, "lon": 9.444851, "expectedCountry": "CH"},
  {"name": "Luxembourg", "stopId": "de-DELFI_lu:25000:NVBW_003", "lat": 49.599712, "lon": 6.134396, "expectedCountry": "LU"},
  {"name": "Sandweiler-Contern", "stopId": "de-DELFI_lu:25000:NVBW_055", "lat": 49.59905, "lon": 6.211921, "expectedCountry": "LU"},
  {"name": "Wasserbillig", "stopId": "de-DELFI_lu:25000:NVBW_011", "lat": 49.71283, "lon": 6.499351, "expectedCountry": "LU"},
  {"name": "Rīgas Centrālā stacija", "stopId": "lt-LTG-Link_Ryga", "lat": 56.9464, "lon": 24.122911, "expectedCountry": "LV"},
  {"name": "Jelgava", "stopId": "lt-LTG-Link_Jelgava", "lat": 56.641438, "lon": 23.733912, "expectedCountry": "LV"},
  {"name": "Joniškis", "stopId": "lt-LTG-Link_Joniškis", "lat": 56.231094, "lon": 23.599255, "expectedCountry": "LT"},
  {"name": "VENTIMIGLIA", "stopId": "fr-horaires-sncf_FR::LMO:a260cb70-337a-11e9-b154-294c36c22c4f:", "lat": 43.792569, "lon": 7.610233, "expectedCountry": "IT"},
  {"name": "Monaco-Monte-Carlo", "stopId": "fr-horaires-sncf_FR::LMO:91653280-cb0a-11e8-8bfa-f784c1c7c611:", "lat": 43.738414, "lon": 7.419747, "expectedCountry": "MC"},
  {"name": "Cap-d'Ail", "stopId": "fr-horaires-sncf_FR::LMO:6b7c9b80-cb0a-11e8-8bfa-f784c1c7c611:", "lat": 43.7206, "lon": 7.394384, "expectedCountry": "FR"},
  {"name": "Gare de Monaco - Pont Sainte Dévote", "stopId": "fr-trains-express-regionaux-zou-en-provence-alpes-cote-d-azur_SNC:VSP:FR::LMO:91653280-cb0a-11e8-8bfa-f784c1c7c611:", "lat": 43.738415, "lon": 7.419747, "expectedCountry": "MC"},
  {"name": "Beograd Centar", "stopId": "me-zpcg_31", "lat": 44.79363, "lon": 20.453129, "expectedCountry": "RS"},
  {"name": "Bijelo Polje", "stopId": "me-zpcg_22", "lat": 43.054348, "lon": 19.769432, "expectedCountry": "ME"},
  {"name": "Bratislava hlavná stanica", "stopId": "ua-ukrzaliznytsya_5600207", "lat": 48.15903, "lon": 17.106468, "expectedCountry": "SK"},
  {"name": "Trnava", "stopId": "ua-ukrzaliznytsya_5600195", "lat": 48.36972, "lon": 17.584915, "expectedCountry": "SK"},
  {"name": "Чоп", "stopId": "ua-ukrzaliznytsya_2200010", "lat": 48.43269, "lon": 22.206951, "expectedCountry": "UA"},
  {"name": "Kyiv-Pas.", "stopId": "hu-mav_1:002232030_0", "lat": 50.439445, "lon": 30.488056, "expectedCountry": "UA"},
  {"name": "Lviv", "stopId": "hu-mav_1:002237000_0", "lat": 49.84028, "lon": 23.994167, "expectedCountry": "UA"},
  {"name": "Záhony", "stopId": "hu-mav_1:005514175_0", "lat": 48.40222, "lon": 22.18361, "expectedCountry": "HU"},
  {"name": "Kyjiw-Passaschyrskyj", "stopId": "at-Railway-Current-Reference-Data-2026_ua:22005:1:1", "lat": 50.43998, "lon": 30.488739, "expectedCountry": "UA"},
  {"name": "Baia Mare", "stopId": "hu-mav_1:005341638_0", "lat": 47.6475, "lon": 23.552778, "expectedCountry": "RO"},
  {"name": "Seini", "stopId": "hu-mav_1:005341822_0", "lat": 47.737778, "lon": 23.285, "expectedCountry": "RO"},
  {"name": "Apa", "stopId": "hu-mav_1:005341846_0", "lat": 47.768055, "lon": 23.187778, "expectedCountry": "RO"},
  {"name": "Mediesu Aurit", "stopId": "hu-mav_1:005341860_0", "lat": 47.775276, "lon": 23.120556, "expectedCountry": "RO"},
  {"name": "Satu Mare", "stopId": "hu-mav_1:005345452_0", "lat": 47.795, "lon": 22.891945, "expectedCountry": "RO"},
  {"name": "Carei", "stopId": "hu-mav_1:005345323_0", "lat": 47.69, "lon": 22.46611, "expectedCountry": "RO"},
  {"name": "Valea lui Mihai", "stopId": "hu-mav_1:005345153_0", "lat": 47.52667, "lon": 22.133057, "expectedCountry": "RO"},
  {"name": "Nyírábrány", "stopId": "hu-mav_1:005515180_0", "lat": 47.523888, "lon": 22.016945, "expectedCountry": "HU"},
  {"name": "Mertert", "stopId": "de-DELFI_lu:25000:NVBW_046", "lat": 49.703255, "lon": 6.478645, "expectedCountry": "LU"},
] satisfies (TransitousJourneyPlace & { expectedCountry: string })[];

const luxembourgCalls = inventoryStations.filter((station) => ["Luxembourg", "Sandweiler-Contern", "Wasserbillig"].includes(station.name));
// Fresh RB83(5631) receipt includes eight additional calls, including Mertert.
const luxembourgRegionalCalls: TransitousJourneyPlace[] = [
  {"name": "Luxembourg", "stopId": "de-DELFI_lu:25000:NVBW_003", "lat": 49.599712, "lon": 6.134396},
  {"name": "Cents-Hamm", "stopId": "de-DELFI_lu:25000:NVBW_028", "lat": 49.61502, "lon": 6.165978},
  {"name": "Sandweiler-Contern", "stopId": "de-DELFI_lu:25000:NVBW_055", "lat": 49.59905, "lon": 6.211921},
  {"name": "Oetrange", "stopId": "de-DELFI_lu:25000:NVBW_052", "lat": 49.602608, "lon": 6.25814},
  {"name": "Munsbach", "stopId": "de-DELFI_lu:25000:NVBW_048", "lat": 49.630257, "lon": 6.268579},
  {"name": "Roodt/Syre", "stopId": "de-DELFI_lu:25000:NVBW_053", "lat": 49.6668, "lon": 6.303071},
  {"name": "Betzdorf(LUX)", "stopId": "de-DELFI_lu:25000:NVBW_026", "lat": 49.68889, "lon": 6.348989},
  {"name": "Wecker", "stopId": "de-DELFI_lu:25000:NVBW_060", "lat": 49.70009, "lon": 6.387365},
  {"name": "Manternach", "stopId": "de-DELFI_lu:25000:NVBW_043", "lat": 49.70646, "lon": 6.423769},
  {"name": "Mertert", "stopId": "de-DELFI_lu:25000:NVBW_046", "lat": 49.703255, "lon": 6.478645},
  {"name": "Wasserbillig", "stopId": "de-DELFI_lu:25000:NVBW_011", "lat": 49.71283, "lon": 6.499351},
];

describe("country inventory regressions", () => {
  it.each(inventoryStations)("keeps $name physically in $expectedCountry through planning and refresh", async (station) => {
    const stops = [station, calls[0]!];
    const planned = normalizedCalls(stops)[0]!.place;
    expect(planned.countryCode).toBe(station.expectedCountry);
    expect(decodeRailPlaceId(planned.id).countryCode).toBe(station.expectedCountry);
    expect(decodeRailPlaceId(planned.id).nativeId).toBe(station.stopId);
    for (let refresh = 0; refresh < 2; refresh += 1) {
      expect((await snapshot(stops)).stops[0]).toMatchObject({
        stationId: `eu:transitous:${station.stopId}`, countryCode: station.expectedCountry,
      });
    }
  });

  it.each([
    ["three-stop express", luxembourgCalls],
    ["eleven-stop regional", luxembourgRegionalCalls],
  ] as const)("selects only the LU overlay for the German-feed %s", async (_description, stops) => {
    const mobiliteit = new MobiliteitLuRealtimeOverlay("fixture-key", "https://official.test");
    const officialCalls = vi.spyOn(mobiliteit, "platformUpdates").mockResolvedValue([]);
    vi.spyOn(mobiliteit, "tripAlertIds").mockResolvedValue([]);
    const germanCalls = vi.fn(async () => []);
    const enricher = new TripSnapshotEnricher([mobiliteit, {
      sourceName: "German overlay", supportedCountryCodes: new Set(["DE"]), platformUpdates: germanCalls,
    }]);
    const countries = stops.map(() => "LU");
    expect(normalizedCalls(stops).map((call) => call.place.countryCode)).toEqual(countries);
    for (let refresh = 0; refresh < 2; refresh += 1) {
      const result = await enricher.enrich(await snapshot(stops));
      expect(result.stops.map((stop) => stop.countryCode)).toEqual(countries);
    }
    expect(officialCalls).toHaveBeenCalledTimes(2);
    expect(germanCalls).not.toHaveBeenCalled();
  });

  it("does not activate Austrian enrichment for Hungarian-only stations in an Austrian feed", async () => {
    const stops = inventoryStations.filter((station) => ["Budapest-Keleti", "Győr"].includes(station.name));
    const austrianCalls = vi.fn(async () => []);
    await new TripSnapshotEnricher([{
      sourceName: "Austrian overlay", supportedCountryCodes: new Set(["AT"]), platformUpdates: austrianCalls,
    }]).enrich(await snapshot(stops));
    expect(austrianCalls).not.toHaveBeenCalled();
  });
});
