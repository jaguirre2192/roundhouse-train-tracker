import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";
import { parseStationBoardRequest, RequestValidationError } from "../src/cloudflare/api-validation.js";
import { diffSnapshots } from "../src/domain/events.js";
import { defaultPushPreferences } from "../src/domain/snapshot.js";
import { RailProviderNotFoundError } from "../src/providers/provider.js";
import { TransitousProvider } from "../src/providers/transitous.js";

describe("TransitousProvider", () => {
  it.each([
    ["2026-07-21T07:00:00Z", "2026-07-21T07:00:00Z", "departures"],
    ["2026-07-21T07:00:00.000Z", "2026-07-21T07:00:00Z", "departures"],
    ["2026-07-21T07:00:00.123456+00:00", "2026-07-21T07:00:00Z", "departures"],
    ["2026-07-21T09:00:00.456+02:00", "2026-07-21T07:00:00Z", "arrivals"],
    ["2026-07-21T00:00:00-07:00", "2026-07-21T07:00:00Z", "departures"],
    ["2026-07-21T00:30:00+02:00", "2026-07-20T22:30:00Z", "arrivals"],
  ])("normalizes the API board timestamp %s before requesting stoptimes", async (at, expectedAt, direction) => {
    let request: URL | undefined;
    const provider = new TransitousProvider("https://example.test", async (input) => {
      request = new URL(String(input));
      return Response.json({ stopTimes: [] });
    });
    const reference = parseStationBoardRequest(new URLSearchParams({
      stationId: "eu:transitous:de-test-berlin-hbf",
      source: "transitous",
      nativeId: "de-test-berlin-hbf",
      at,
      direction,
    }));

    await provider.fetchBoard(reference);

    expect(reference).toEqual({
      stationId: "eu:transitous:de-test-berlin-hbf",
      source: "transitous",
      nativeId: "de-test-berlin-hbf",
      at: expectedAt,
      direction,
    });
    expect(request?.searchParams.get("time")).toBe(expectedAt);
    expect(request?.searchParams.get("arriveBy")).toBe(String(direction === "arrivals"));
  });

  it.each(["not-a-timestamp", "2026-13-21T07:00:00Z", ""])(
    "rejects the invalid API board timestamp %s before provider lookup",
    (at) => {
      let error: unknown;
      try {
        parseStationBoardRequest(new URLSearchParams({
          stationId: "eu:transitous:de-test-berlin-hbf",
          source: "transitous",
          nativeId: "de-test-berlin-hbf",
          at,
          direction: "departures",
        }));
      } catch (caught) {
        error = caught;
      }

      expect(error).toBeInstanceOf(RequestValidationError);
      expect(error).toMatchObject({
        issues: expect.arrayContaining(["at must be an ISO timestamp"]),
      });
    },
  );

  it("normalizes a European trip with planned and expected platforms", async () => {
    const fixture = await readFile(new URL("../../Packages/TrainTrackerCore/Tests/TrainTrackerCoreTests/Fixtures/Transitous/trip.json", import.meta.url));
    let request: URL | undefined;
    const provider = new TransitousProvider(
      "https://example.test",
      async (input) => {
        request = new URL(String(input));
        return new Response(fixture, { status: 200 });
      },
      () => new Date("2026-07-21T07:00:00.000Z"),
    );

    const trip = await provider.fetchTrip({
      id: "eu:transitous:europe-9572",
      source: "transitous",
      nativeId: "europe-9572",
      serviceDate: "2026-07-21",
    });

    expect(trip.product).toBe("ICE 9572");
    expect(trip.stops[0]).toMatchObject({
      stationId: "eu:transitous:de-test-berlin-hbf",
      plannedPlatform: "7",
      expectedPlatform: "8",
    });
    expect(trip.stops.at(-1)?.stationName).toBe("Paris Est");
    expect(trip.routeGeometry).toEqual({
      source: "Transitous/MOTIS",
      segments: [{
        encodedPolyline: "_p~iF~ps|U_ulLnnqC_mqNvxq`@",
        precision: 5,
        pointCount: 3,
      }],
    });
    expect(request?.searchParams.get("detailedLegs")).toBe("true");
  });

  it("serves provider-neutral international discovery and boards", async () => {
    const geocode = await readFile(new URL("../../Packages/TrainTrackerCore/Tests/TrainTrackerCoreTests/Fixtures/Transitous/geocode.json", import.meta.url));
    const stoptimes = await readFile(new URL("../../Packages/TrainTrackerCore/Tests/TrainTrackerCoreTests/Fixtures/Transitous/stoptimes.json", import.meta.url));
    const provider = new TransitousProvider(
      "https://example.test",
      async (input) => new Response(new URL(String(input)).pathname.includes("geocode") ? geocode : stoptimes, { status: 200 }),
      () => new Date("2026-07-21T07:00:00.000Z"),
    );

    const stations = await provider.searchStations("Berlin");
    expect(stations[0]).toMatchObject({ source: "transitous", countryCode: "DE" });

    const board = await provider.fetchBoard({
      stationId: stations[0]!.id,
      source: "transitous",
      nativeId: stations[0]!.nativeId,
      at: "2026-07-21T07:00:00.000Z",
      direction: "departures",
    });
    expect(board[0]).toMatchObject({
      trip: expect.objectContaining({ source: "transitous" }),
      stop: expect.objectContaining({ countryCode: "DE" }),
    });
  });

  it("expands Tokyo aliases but excludes Tokyo urban-only feeds", async () => {
    const requested: string[] = [];
    const provider = new TransitousProvider(
      "https://example.test",
      async (input) => {
        const text = new URL(String(input)).searchParams.get("text")!;
        requested.push(text);
        return Response.json(text === "Tokyo" ? [{
          type: "STOP",
          name: "Tōkyō",
          id: "jp-tokyo-rail_Tokyo",
          lat: 35.681,
          lon: 139.767,
          country: "JP",
        }] : [{
          type: "STOP",
          name: "Tobo station",
          id: "se-unrelated-tobo",
          lat: 58,
          lon: 15,
          country: "SE",
        }]);
      },
    );

    const stations = await provider.searchStations("Tokyo Station");

    expect(requested).toEqual(["Tokyo", "Tokyo Station"]);
    expect(stations).not.toContainEqual(expect.objectContaining({ countryCode: "JP" }));
  });

  it("keeps VIA Rail and V/Line while rejecting commuter-only station feeds", async () => {
    const provider = new TransitousProvider(
      "https://example.test",
      async () => Response.json([
        { type: "STOP", name: "Montréal", id: "ca-Viarail_226", lat: 45.5, lon: -73.57, country: "CA" },
        { type: "STOP", name: "Montréal", id: "ca-qc-exo_1000", lat: 45.5, lon: -73.57, country: "CA" },
        { type: "STOP", name: "Southern Cross", id: "au-vic-Transport-Victoria-interstate_vic:rail:SSS", lat: -37.81, lon: 144.95, country: "AU" },
        { type: "STOP", name: "Central", id: "au-nsw-sydney-trains_200060", lat: -33.88, lon: 151.21, country: "AU" },
      ]),
    );

    const stations = await provider.searchStations("central station");

    expect(stations.map((station) => station.nativeId)).toEqual([
      "ca-Viarail_226",
      "au-vic-Transport-Victoria-interstate_vic:rail:SSS",
    ]);
  });

  it("discovers Transwa rail stations hidden by upstream bus metadata", async () => {
    const provider = new TransitousProvider(
      "https://example.test",
      async () => Response.json([]),
    );

    const stations = await provider.searchStations("Kalgoorlie");

    expect(stations).toContainEqual(expect.objectContaining({
      name: "Kalgoorlie (Transwa)",
      countryCode: "AU",
      nativeId: "au-wa-Transperth_95058|au-wa-Transperth_95059",
      operatorHints: ["Transwa"],
    }));
  });

  it("merges both directional Transwa stop boards and keeps only named rail services", async () => {
    const requested: string[] = [];
    const place = (stopId: string, departure: string) => ({
      name: "East Perth Stn Transwa East Perth",
      stopId,
      lat: -31.943974,
      lon: 115.87715,
      scheduledDeparture: departure,
      departure,
    });
    const provider = new TransitousProvider(
      "https://example.test",
      async (input) => {
        const stopId = new URL(String(input)).searchParams.get("stopId")!;
        requested.push(stopId);
        const shared = {
          place: place(stopId, "2026-07-23T09:25:00Z"),
          mode: "REGIONAL_RAIL",
          tripId: "20260723_17:25_au-wa-Transperth_6929759",
          routeLongName: "AvonLink",
          headsign: "Northam",
        };
        return Response.json({ stopTimes: stopId.endsWith("95024") ? [
          shared,
          { ...shared, tripId: "20260723_au-wa-Transperth_urban", routeLongName: "Airport Line" },
        ] : [shared] });
      },
    );

    const board = await provider.fetchBoard({
      stationId: "eu:transitous:au-wa-Transperth_95024|au-wa-Transperth_95025",
      source: "transitous",
      nativeId: "au-wa-Transperth_95024|au-wa-Transperth_95025",
      at: "2026-07-23T00:00:00Z",
      direction: "departures",
    });

    expect(requested).toEqual(["au-wa-Transperth_95024", "au-wa-Transperth_95025"]);
    expect(board.map((entry) => entry.trip.nativeId)).toEqual([
      "20260723_17:25_au-wa-Transperth_6929759",
    ]);
  });

  it("turns VIA Rail realtime changes into delay, cancellation, and disruption events", async () => {
    const provider = new TransitousProvider(
      "https://example.test",
      async () => Response.json({
        legs: [{
          mode: "REGIONAL_RAIL",
          tripId: "20260721_16:38_ca-Viarail_455",
          agencyName: "VIA Rail",
          displayName: "VIA Rail 455",
          headsign: "Toronto",
          from: {
            name: "Montréal",
            stopId: "ca-Viarail_226",
            lat: 45.49992,
            lon: -73.56618,
            scheduledDeparture: "2026-07-21T21:00:00Z",
            departure: "2026-07-21T21:07:00Z",
            alerts: [{
              code: "via-455-service-update",
              headerText: "Service update",
              descriptionText: "Operating conditions are affecting this train.",
            }],
          },
          to: {
            name: "Toronto",
            stopId: "ca-Viarail_277",
            lat: 43.6453,
            lon: -79.3806,
            scheduledArrival: "2026-07-22T01:10:00Z",
            arrival: "2026-07-22T01:10:00Z",
            cancelled: true,
          },
        }],
      }),
      () => new Date("2026-07-21T20:00:00Z"),
    );

    const current = await provider.fetchTrip({
      id: "eu:transitous:20260721_16:38_ca-Viarail_455",
      source: "transitous",
      nativeId: "20260721_16:38_ca-Viarail_455",
      serviceDate: "2026-07-21",
    });
    const previous = {
      ...current,
      fetchedAt: "2026-07-21T19:59:00Z",
      alertIds: [],
      stops: current.stops.map((stop) => ({
        ...stop,
        expectedArrival: stop.scheduledArrival,
        expectedDeparture: stop.scheduledDeparture,
        cancelled: false,
      })),
    };

    expect(current.alertIds).toEqual(["transitous-alert-via-455-service-update"]);
    expect(diffSnapshots(previous, current, defaultPushPreferences).map((event) => event.kind)).toEqual([
      "delay-threshold",
      "cancellation",
      "disruption",
    ]);
  });

  it("expands English Israeli rail hubs to official Hebrew station names", async () => {
    const requested: string[] = [];
    const provider = new TransitousProvider(
      "https://example.test",
      async (input) => {
        const url = new URL(String(input));
        requested.push(url.searchParams.get("text") ?? "");
        return Response.json(url.searchParams.get("text") === "תל אביב מרכז" ? [{
          type: "STOP",
          name: "תל אביב מרכז",
          id: "il-Israel-MOT_37358",
          lat: 32.083,
          lon: 34.796,
          country: "IL",
        }] : []);
      },
    );

    const stations = await provider.searchStations("Tel Aviv Savidor Center");

    expect(requested).toEqual(["תל אביב מרכז", "Tel Aviv Savidor Center"]);
    expect(stations).toContainEqual(expect.objectContaining({
      nativeId: "il-Israel-MOT_37358",
      countryCode: "IL",
    }));
  });

  it("prefers French mainline stations over Île-de-France commuter duplicates", async () => {
    const provider = new TransitousProvider(
      "https://example.test",
      async () => Response.json([
        { type: "STOP", name: "Gare de Lyon", id: "fr-reseau-urbain-et-interurbain-dile-de-france-mobilites_IDFM:73626", lat: 48.84, lon: 2.37, country: "FR" },
        { type: "STOP", name: "Paris Gare de Lyon", id: "ch-opentransportdataswiss26_Parent8768600", lat: 48.84, lon: 2.37, country: "FR" },
      ]),
    );

    const stations = await provider.searchStations("Paris Gare de Lyon");

    expect(stations.map((station) => station.nativeId)).toEqual(["ch-opentransportdataswiss26_Parent8768600"]);
  });

  it("filters non-intercity departures from mixed regional-rail boards", async () => {
    const place = {
      name: "Central",
      stopId: "au-test-central",
      lat: -33.88,
      lon: 151.21,
      scheduledDeparture: "2026-07-21T08:00:00Z",
      departure: "2026-07-21T08:00:00Z",
    };
    const provider = new TransitousProvider(
      "https://example.test",
      async () => Response.json({ stopTimes: [
        { place, mode: "REGIONAL_RAIL", tripId: "20260721_au-nsw-sydney-trains_T2", headsign: "Leppington" },
        { place, mode: "REGIONAL_RAIL", tripId: "20260721_au-nsw-nsw-trains_621", headsign: "Melbourne" },
      ] }),
    );

    const board = await provider.fetchBoard({
      stationId: "eu:transitous:au-test-central",
      source: "transitous",
      nativeId: "au-test-central",
      at: "2026-07-21T07:00:00Z",
      direction: "departures",
    });

    expect(board.map((entry) => entry.trip.nativeId)).toEqual(["20260721_au-nsw-nsw-trains_621"]);
  });

  it("keeps only the boarded Japanese run when Transitous returns later interlined loops", async () => {
    const selected = "20260721_17:44_jp-tokyo-rail_JR-East.Yamanote.1730G.Weekday";
    const place = (name: string, id: string, time: string) => ({
      name,
      stopId: id,
      lat: 35.68,
      lon: 139.76,
      tz: "Asia/Tokyo",
      scheduledArrival: time,
      scheduledDeparture: time,
    });
    const itinerary = {
      legs: [
        {
          mode: "REGIONAL_RAIL",
          tripId: selected,
          agencyName: "JR East",
          routeShortName: "JY",
          tripShortName: "1730G",
          from: place("Ōsaki", "jp-tokyo-rail_Osaki", "2026-07-21T08:44:00Z"),
          intermediateStops: [place("Tokyo", "jp-tokyo-rail_Tokyo", "2026-07-21T09:01:00Z")],
          to: place("Ōsaki", "jp-tokyo-rail_Osaki", "2026-07-21T09:50:00Z"),
        },
        {
          mode: "REGIONAL_RAIL",
          tripId: "20260721_18:52_jp-tokyo-rail_JR-East.Yamanote.1830G.Weekday",
          agencyName: "JR East",
          routeShortName: "JY",
          tripShortName: "1830G",
          from: place("Ōsaki", "jp-tokyo-rail_Osaki", "2026-07-21T09:52:00Z"),
          intermediateStops: [place("Tokyo", "jp-tokyo-rail_Tokyo", "2026-07-21T10:12:00Z")],
          to: place("Ōsaki", "jp-tokyo-rail_Osaki", "2026-07-21T10:58:00Z"),
        },
      ],
    };
    const provider = new TransitousProvider(
      "https://example.test",
      async () => Response.json(itinerary),
      () => new Date("2026-07-21T08:45:00Z"),
    );

    const trip = await provider.fetchTrip({
      id: `eu:transitous:${selected}`,
      source: "transitous",
      nativeId: selected,
      serviceDate: "2026-07-21",
    });

    expect(trip.stops).toHaveLength(3);
    expect(trip.stops.map((stop) => stop.stationName)).toEqual(["Ōsaki", "Tokyo", "Ōsaki"]);
  });

  it("throws the typed provider error when a requested trip is absent", async () => {
    const provider = new TransitousProvider(
      "https://example.test",
      async () => Response.json({ legs: [] }),
    );

    await expect(provider.fetchTrip({
      id: "eu:transitous:missing",
      source: "transitous",
      nativeId: "missing",
      serviceDate: "2026-07-21",
    })).rejects.toBeInstanceOf(RailProviderNotFoundError);
  });
});
