import { readFile } from "node:fs/promises";
import { afterEach, describe, expect, it, vi } from "vitest";
import { decodeRailPlaceId, encodeRailPlaceId } from "../src/providers/rail-place-id.js";
import { TransitousJourneyProvider } from "../src/providers/transitous-journeys.js";
import { JourneyProviderUnavailableError } from "../src/providers/journey-provider.js";
import type { TransitousPlanResponse } from "../src/providers/transitous-journey-types.js";

const fixedNow = new Date("2026-07-21T19:00:00Z");
const baseUrl = "https://example.test";

async function jsonFixture<T>(name: string): Promise<T> {
  return JSON.parse(await readFile(new URL(`fixtures/journeys/${name}`, import.meta.url), "utf8")) as T;
}

function stationId(nativeId: string, countryCode: string): string {
  return encodeRailPlaceId({
    provider: "transitous",
    kind: "station",
    nativeId,
    countryCode,
    latitude: null,
    longitude: null,
  });
}

function cityId(nativeId: string, countryCode: string, latitude: number, longitude: number): string {
  return encodeRailPlaceId({
    provider: "transitous",
    kind: "city",
    nativeId,
    countryCode,
    latitude,
    longitude,
  });
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("TransitousJourneyProvider place search", () => {
  it("normalizes and ranks an exact Paris city before mainline station matches", async () => {
    const payload = await jsonFixture<unknown[]>("place-search-paris.json");
    let request: URL | undefined;
    const provider = new TransitousJourneyProvider(baseUrl, async (input) => {
      request = new URL(String(input));
      return Response.json(payload);
    }, () => fixedNow);

    const places = await provider.searchPlaces(" Paris ", 5);

    expect(request?.pathname).toBe("/api/v1/geocode");
    expect(Object.fromEntries(request?.searchParams ?? [])).toEqual({
      text: "Paris",
      mode: "HIGHSPEED_RAIL,LONG_DISTANCE,NIGHT_RAIL,REGIONAL_RAIL",
      language: "en",
      numResults: "50",
    });
    expect(places.map((place) => place.displayName)).toEqual([
      "Paris",
      "Paris-Nord",
      "Paris Est",
      "Paris Gare de Lyon",
      "Paris Austerlitz",
    ]);
    expect(places[0]).toMatchObject({
      kind: "city",
      countryCode: "FR",
      timeZoneIdentifier: "Europe/Paris",
      location: { latitude: 48.853495, longitude: 2.348392 },
      attributions: ["Transitous", "OpenStreetMap contributors"],
    });
    expect(places.every((place) => decodeRailPlaceId(place.id).provider === "transitous")).toBe(true);
    expect(decodeRailPlaceId(places[1]!.id)).toMatchObject({
      kind: "station",
      nativeId: "de-DELFI_000008700014",
      latitude: null,
      longitude: null,
    });
  });

  it("ranks an exact station before non-exact city, prefix, and fuzzy matches", async () => {
    const payload = await jsonFixture<unknown[]>("place-search-paris.json");
    const provider = new TransitousJourneyProvider(baseUrl, async () => Response.json(payload), () => fixedNow);

    const places = await provider.searchPlaces("Paris-Nord", 3);

    expect(places[0]?.displayName).toBe("Paris-Nord");
    expect(places).toHaveLength(3);
  });

  it("keeps place suggestions while the user is still typing a token", async () => {
    const payload = await jsonFixture<unknown[]>("place-search-paris.json");
    const provider = new TransitousJourneyProvider(baseUrl, async () => Response.json(payload), () => fixedNow);

    const places = await provider.searchPlaces("pari", 3);

    expect(places.map((place) => place.displayName)).toEqual([
      "Paris",
      "Paris-Nord",
      "Paris Est",
    ]);
  });

  it("offers a city only near an accepted same-country mainline stop in enabled coverage", async () => {
    const provider = new TransitousJourneyProvider(baseUrl, async () => Response.json([
      {
        type: "PLACE", name: "Eligible", id: "node/eligible", lat: 48.8535, lon: 2.3484,
        country: "FR", tz: "Europe/Paris", category: "place_6", modes: null,
      },
      {
        type: "STOP", name: "Eligible Central", id: "fr-mainline_eligible", lat: 48.8809, lon: 2.3553,
        country: "FR", tz: "Europe/Paris", modes: ["LONG_DISTANCE"],
      },
      {
        type: "PLACE", name: "Far Away", id: "node/far", lat: 43.2965, lon: 5.3698,
        country: "FR", tz: "Europe/Paris", modes: null,
      },
      {
        type: "PLACE", name: "Taipei", id: "node/taipei", lat: 25.0478, lon: 121.517,
        country: "TW", tz: "Asia/Taipei", modes: null,
      },
      {
        type: "STOP", name: "Taipei Main", id: "tw-mainline_taipei", lat: 25.0478, lon: 121.517,
        country: "TW", tz: "Asia/Taipei", modes: ["HIGHSPEED_RAIL"],
      },
      {
        type: "PLACE", name: "Urban Only", id: "node/urban", lat: 43.2966, lon: 5.3699,
        country: "FR", tz: "Europe/Paris", modes: null,
      },
      {
        type: "STOP", name: "Urban Only RER", id: "fr-idf_IDFM:urban", lat: 43.2966, lon: 5.3699,
        country: "FR", tz: "Europe/Paris", modes: ["REGIONAL_RAIL"],
      },
    ]), () => fixedNow);

    const places = await provider.searchPlaces("eligible", 20);

    expect(places.map((place) => place.displayName)).toEqual([
      "Eligible",
      "Eligible Central",
    ]);
  });

  it("omits named points of interest even when they are close to accepted mainline rail", async () => {
    const payload = await jsonFixture<unknown[]>("place-search-edinburgh-pois.json");
    const provider = new TransitousJourneyProvider(baseUrl, async () => Response.json(payload), () => fixedNow);

    const places = await provider.searchPlaces("Edinburgh", 20);

    expect(places.map((place) => place.displayName)).toEqual([
      "Edinburgh",
      "Edinburgh Waverley",
    ]);
  });

  it("deduplicates canonical nearby cities before applying the result limit and preserves stations", async () => {
    const payload = await jsonFixture<unknown[]>("place-search-city-duplicates.json");
    const provider = new TransitousJourneyProvider(baseUrl, async () => Response.json(payload), () => fixedNow);

    const places = await provider.searchPlaces("Paris", 4);

    expect(places.map((place) => place.displayName)).toEqual(["Paris", "Paris Gare du Nord"]);
    expect(decodeRailPlaceId(places[0]!.id).nativeId).toBe("node/[17807753]");
  });

  it("deduplicates provider-identical cities before the limit without collapsing nearby municipalities", async () => {
    const payload = await jsonFixture<unknown[]>("place-search-city-equivalence.json");
    const provider = new TransitousJourneyProvider(baseUrl, async () => Response.json(payload), () => fixedNow);

    const places = await provider.searchPlaces("Springfield", 6);

    expect(places.map((place) => `${place.countryCode}:${place.displayName}`)).toEqual([
      "FR:Springfield",
      "FR:Springfield",
      "DE:Springfield",
      "FR:Springfield West",
      "FR:Springfield East",
      "DE:Springfield Hauptbahnhof",
    ]);
    expect(places.filter((place) => place.kind === "station")).toHaveLength(3);
    expect(places.filter((place) => place.kind === "city").map((place) => decodeRailPlaceId(place.id).nativeId)).toEqual([
      "node/[springfield-fr-west]",
      "node/[springfield-fr-east]",
      "node/[springfield-de]",
    ]);
    expect(places[0]?.timeZoneIdentifier).toBe("Europe/Paris");
    expect(places[2]?.timeZoneIdentifier).toBe("Europe/Berlin");
  });

  it("resolves Washington DC to Union Station and rejects the distant junction", async () => {
    const payload = await jsonFixture<unknown[]>("place-search-washington-dc.json");
    const provider = new TransitousJourneyProvider(baseUrl, async () => Response.json(payload), () => fixedNow);

    const places = await provider.searchPlaces("Washington dc", 20);

    expect(places.map((place) => place.displayName)).toEqual(["Union Station, Washington, DC"]);
    expect(places[0]).toMatchObject({
      kind: "station",
      timeZoneIdentifier: "America/New_York",
      countryCode: "US",
    });
    expect(places).not.toContainEqual(expect.objectContaining({ displayName: "WASHINGTON JUNCTION" }));
  });

  it("keeps only complete query-token matches when no exact city anchors the result", async () => {
    const payload = await jsonFixture<unknown[]>("place-search-new-york-penn.json");
    const provider = new TransitousJourneyProvider(baseUrl, async () => Response.json(payload), () => fixedNow);

    const places = await provider.searchPlaces("New York Penn", 20);

    expect(places.map((place) => place.displayName)).toEqual(["NEW YORK PENN STATION"]);
  });

  it("keeps the relevant station for a partially typed multiword query", async () => {
    const payload = await jsonFixture<unknown[]>("place-search-new-york-penn.json");
    const provider = new TransitousJourneyProvider(baseUrl, async () => Response.json(payload), () => fixedNow);

    const places = await provider.searchPlaces("New York Pen", 20);

    expect(places.map((place) => place.displayName)).toEqual(["NEW YORK PENN STATION"]);
  });

  it("default-denies malformed geocode entries instead of leaking parser details", async () => {
    const provider = new TransitousJourneyProvider(baseUrl, async () => Response.json([{
      type: "STOP",
      name: "Private diagnostics",
      id: "fr-mainline_private",
      lat: 48.88,
      lon: 2.35,
      country: "FR",
      tz: "Europe/Paris",
      modes: "/srv/transitous/private.ts",
    }]), () => fixedNow);

    await expect(provider.searchPlaces("Paris", 5)).resolves.toEqual([]);
  });

  it("does not let a nearby enabled foreign-country stop make a city eligible", async () => {
    const provider = new TransitousJourneyProvider(baseUrl, async () => Response.json([
      {
        type: "PLACE", name: "Border City", id: "node/border", lat: 46.2044, lon: 6.1432,
        country: "FR", tz: "Europe/Paris", modes: null,
      },
      {
        type: "STOP", name: "Swiss Mainline", id: "ch-mainline_border", lat: 46.2044, lon: 6.1432,
        country: "CH", tz: "Europe/Zurich", modes: ["LONG_DISTANCE"],
      },
    ]), () => fixedNow);

    const places = await provider.searchPlaces("border", 20);

    expect(places).toEqual([]);
  });
});

describe("TransitousJourneyProvider journey search", () => {
  it("plans exact stops for Depart At with fixed safe parameters and normalized provider cursors", async () => {
    const payload = await jsonFixture<TransitousPlanResponse>("paris-amsterdam.json");
    let request: URL | undefined;
    let requestInit: RequestInit | undefined;
    const provider = new TransitousJourneyProvider(baseUrl, async (input, init) => {
      request = new URL(String(input));
      requestInit = init;
      return Response.json(payload);
    }, () => fixedNow);

    const result = await provider.searchJourneys({
      originId: stationId("fr-eurostar_paris_nord", "FR"),
      destinationId: stationId("nl-openov_amsterdam_centraal", "NL"),
      time: "2026-07-24T08:00:00+02:00",
      arriveBy: false,
      maxTransfers: 9,
      providerCursor: null,
    });

    expect(request?.pathname).toBe("/api/v6/plan");
    expect(Object.fromEntries(request?.searchParams ?? [])).toEqual({
      fromPlace: "fr-eurostar_paris_nord",
      toPlace: "nl-openov_amsterdam_centraal",
      maxTransfers: "4",
      transitModes: "HIGHSPEED_RAIL,LONG_DISTANCE,NIGHT_RAIL,REGIONAL_RAIL",
      directModes: "",
      detailedLegs: "false",
      detailedTransfers: "false",
      joinInterlinedLegs: "false",
      language: "en",
      time: "2026-07-24T08:00:00+02:00",
      arriveBy: "false",
    });
    expect(request?.searchParams.has("pageCursor")).toBe(false);
    expect(new Headers(requestInit?.headers).get("user-agent")).toBe(
      "Roundhouse/0.1.0 (+https://gettraintracker.com/support)",
    );
    expect(result).toMatchObject({
      previousProviderCursor: "EARLIER|1784872800",
      nextProviderCursor: "LATER|1784879760",
      attributions: ["Transitous", "OpenStreetMap contributors"],
    });
    expect(result.options).toHaveLength(2);
    expect(result.options[0]).toMatchObject({
      transferCount: 0,
      attributions: ["Transitous", "OpenStreetMap contributors"],
      trackingToken: "",
    });
    expect(JSON.stringify(result)).not.toContain("provider-direct-paris-amsterdam");
  });

  it("maps legacy Washington and New York city selections to their routeable Amtrak stations", async () => {
    const payload = await jsonFixture<TransitousPlanResponse>("paris-amsterdam.json");
    let request: URL | undefined;
    const provider = new TransitousJourneyProvider(baseUrl, async (input) => {
      request = new URL(String(input));
      return Response.json(payload);
    }, () => fixedNow);

    await provider.searchJourneys({
      originId: cityId("node/[158368533]", "US", 38.8950982, -77.0363849),
      destinationId: cityId("node/[61785451]", "US", 40.7127281, -74.0060152),
      time: "2026-09-15T21:31:00-04:00",
      arriveBy: false,
      maxTransfers: 4,
      providerCursor: null,
    });

    expect(request?.searchParams.get("fromPlace")).toBe("us-Amtrak_WAS");
    expect(request?.searchParams.get("toPlace")).toBe("us-Amtrak_NYP");
    expect(request?.searchParams.has("radius")).toBe(false);
  });

  it("accepts a provider walk leg when Transitous omits its inapplicable route type", async () => {
    const payload = await jsonFixture<TransitousPlanResponse>("paris-amsterdam.json");
    const walk = payload.itineraries[1]!.legs[1]!;
    expect(walk.mode).toBe("WALK");
    delete (walk as Partial<typeof walk>).routeType;
    const provider = new TransitousJourneyProvider(baseUrl, async () => Response.json(payload), () => fixedNow);

    const result = await provider.searchJourneys({
      originId: stationId("fr-eurostar_paris_nord", "FR"),
      destinationId: stationId("nl-openov_amsterdam_centraal", "NL"),
      time: "2026-07-24T08:00:00+02:00",
      arriveBy: false,
      maxTransfers: 4,
      providerCursor: null,
    });

    expect(result.options).toHaveLength(2);
  });

  it("plans city coordinates for Arrive By and keeps the requested transfer cap", async () => {
    const payload = await jsonFixture<TransitousPlanResponse>("paris-amsterdam.json");
    let request: URL | undefined;
    const provider = new TransitousJourneyProvider(baseUrl, async (input) => {
      request = new URL(String(input));
      return Response.json(payload);
    }, () => fixedNow);

    await provider.searchJourneys({
      originId: cityId("node/[17807753]", "FR", 48.853495, 2.348392),
      destinationId: cityId("node/[271110]", "NL", 52.3676, 4.9041),
      time: "2026-07-24T11:30:00+02:00",
      arriveBy: true,
      maxTransfers: 2,
      providerCursor: null,
    });

    expect(request?.searchParams.get("fromPlace")).toBe("48.853495,2.348392");
    expect(request?.searchParams.get("toPlace")).toBe("52.3676,4.9041");
    expect(request?.searchParams.get("time")).toBe("2026-07-24T11:30:00+02:00");
    expect(request?.searchParams.get("arriveBy")).toBe("true");
    expect(request?.searchParams.get("maxTransfers")).toBe("2");
    expect(request?.searchParams.get("radius")).toBe("10000");
  });

  it("rejects an excluded-country place before any upstream fetch", async () => {
    let fetchCount = 0;
    const provider = new TransitousJourneyProvider(baseUrl, async () => {
      fetchCount += 1;
      return Response.json(await jsonFixture<TransitousPlanResponse>("paris-amsterdam.json"));
    }, () => fixedNow);

    const pending = provider.searchJourneys({
      originId: cityId("node/taipei", "TW", 25.0478, 121.517),
      destinationId: stationId("fr-eurostar_paris_nord", "FR"),
      time: "2026-07-24T08:00:00+02:00",
      arriveBy: false,
      maxTransfers: 4,
      providerCursor: null,
    });

    await expect(pending).rejects.toThrow("Rail place is not eligible for journey planning");
    expect(fetchCount).toBe(0);
  });

  it("rejects a forged urban exact-station ID before any upstream fetch", async () => {
    let fetchCount = 0;
    const provider = new TransitousJourneyProvider(baseUrl, async () => {
      fetchCount += 1;
      return Response.json(await jsonFixture<TransitousPlanResponse>("paris-amsterdam.json"));
    }, () => fixedNow);

    const pending = provider.searchJourneys({
      originId: stationId("fr-idf_IDFM:urban", "DE"),
      destinationId: stationId("fr-eurostar_paris_nord", "FR"),
      time: "2026-07-24T08:00:00+02:00",
      arriveBy: false,
      maxTransfers: 4,
      providerCursor: null,
    });

    await expect(pending).rejects.toThrow("Rail place is not eligible for journey planning");
    expect(fetchCount).toBe(0);
  });

  it("rejects a relabeled excluded-country exact-station ID before any upstream fetch", async () => {
    let fetchCount = 0;
    const provider = new TransitousJourneyProvider(baseUrl, async () => {
      fetchCount += 1;
      return Response.json(await jsonFixture<TransitousPlanResponse>("paris-amsterdam.json"));
    }, () => fixedNow);

    const pending = provider.searchJourneys({
      originId: stationId("tw-mainline_taipei", "FR"),
      destinationId: stationId("fr-eurostar_paris_nord", "FR"),
      time: "2026-07-24T08:00:00+02:00",
      arriveBy: false,
      maxTransfers: 4,
      providerCursor: null,
    });

    await expect(pending).rejects.toThrow("Rail place is not eligible for journey planning");
    expect(fetchCount).toBe(0);
  });

  it("uses only the already-validated provider cursor for pagination", async () => {
    const payload = await jsonFixture<TransitousPlanResponse>("paris-amsterdam.json");
    let request: URL | undefined;
    const provider = new TransitousJourneyProvider(baseUrl, async (input) => {
      request = new URL(String(input));
      return Response.json(payload);
    }, () => fixedNow);

    await provider.searchJourneys({
      originId: stationId("fr-eurostar_paris_nord", "FR"),
      destinationId: stationId("nl-openov_amsterdam_centraal", "NL"),
      time: "2026-07-24T08:00:00+02:00",
      arriveBy: false,
      maxTransfers: 4,
      providerCursor: "LATER|1784879760",
    });

    expect(request?.searchParams.get("pageCursor")).toBe("LATER|1784879760");
    expect(request?.searchParams.has("time")).toBe(false);
    expect(request?.searchParams.has("arriveBy")).toBe(false);
  });

  it("preserves returned provider cursors as opaque byte-for-byte values", async () => {
    const payload = await jsonFixture<TransitousPlanResponse>("paris-amsterdam.json");
    payload.previousPageCursor = " opaque cursor with spaces ";
    const provider = new TransitousJourneyProvider(baseUrl, async () => Response.json(payload), () => fixedNow);

    const result = await provider.searchJourneys({
      originId: stationId("fr-eurostar_paris_nord", "FR"),
      destinationId: stationId("nl-openov_amsterdam_centraal", "NL"),
      time: "2026-07-24T08:00:00+02:00",
      arriveBy: false,
      maxTransfers: 4,
      providerCursor: null,
    });

    expect(result.previousProviderCursor).toBe(" opaque cursor with spaces ");
  });

  it("rejects a successful plan response containing invalid timestamps or duration", async () => {
    const invalidTimestamp = await jsonFixture<TransitousPlanResponse>("paris-amsterdam.json");
    invalidTimestamp.itineraries[0]!.legs[0]!.startTime = "not-a-timestamp";
    const invalidDuration = await jsonFixture<TransitousPlanResponse>("paris-amsterdam.json");
    invalidDuration.itineraries[0]!.duration = Number.NaN;
    const request = {
      originId: stationId("fr-eurostar_paris_nord", "FR"),
      destinationId: stationId("nl-openov_amsterdam_centraal", "NL"),
      time: "2026-07-24T08:00:00+02:00",
      arriveBy: false,
      maxTransfers: 4,
      providerCursor: null,
    };

    const timestampProvider = new TransitousJourneyProvider(
      baseUrl,
      async () => Response.json(invalidTimestamp),
      () => fixedNow,
    );
    const durationProvider = new TransitousJourneyProvider(
      baseUrl,
      async () => Response.json(invalidDuration),
      () => fixedNow,
    );

    await expect(timestampProvider.searchJourneys(request)).rejects.toThrow("Transitous returned an invalid response");
    await expect(durationProvider.searchJourneys(request)).rejects.toThrow("Transitous returned an invalid response");
  });

  it("rejects a successful plan response with an incomplete required place", async () => {
    const payload = await jsonFixture<TransitousPlanResponse>("paris-amsterdam.json");
    delete (payload.itineraries[0]!.legs[0]!.from as Partial<typeof payload.itineraries[0]["legs"][0]["from"]>).name;
    const provider = new TransitousJourneyProvider(baseUrl, async () => Response.json(payload), () => fixedNow);

    const pending = provider.searchJourneys({
      originId: stationId("fr-eurostar_paris_nord", "FR"),
      destinationId: stationId("nl-openov_amsterdam_centraal", "NL"),
      time: "2026-07-24T08:00:00+02:00",
      arriveBy: false,
      maxTransfers: 4,
      providerCursor: null,
    });

    await expect(pending).rejects.toThrow("Transitous returned an invalid response");
  });

  it("rejects a successful plan response with reversed itinerary and leg times", async () => {
    const payload = await jsonFixture<TransitousPlanResponse>("paris-amsterdam.json");
    const itinerary = payload.itineraries[0]!;
    payload.itineraries = [itinerary];
    itinerary.startTime = "2026-07-24T11:00:00Z";
    itinerary.endTime = "2026-07-24T10:00:00Z";
    itinerary.legs[0]!.startTime = "2026-07-24T11:00:00Z";
    itinerary.legs[0]!.endTime = "2026-07-24T10:00:00Z";
    const provider = new TransitousJourneyProvider(baseUrl, async () => Response.json(payload), () => fixedNow);

    const pending = provider.searchJourneys({
      originId: stationId("fr-eurostar_paris_nord", "FR"),
      destinationId: stationId("nl-openov_amsterdam_centraal", "NL"),
      time: "2026-07-24T08:00:00+02:00",
      arriveBy: false,
      maxTransfers: 4,
      providerCursor: null,
    });

    await expect(pending).rejects.toThrow(/^Transitous returned an invalid response$/u);
  });

  it("applies the fixed twenty-second timeout and returns a safe timeout error", async () => {
    const controller = new AbortController();
    const timeout = vi.spyOn(AbortSignal, "timeout").mockReturnValue(controller.signal);
    const provider = new TransitousJourneyProvider(baseUrl, async (_input, init) =>
      new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => {
          reject(new DOMException("private provider diagnostics", "AbortError"));
        });
      }), () => fixedNow);

    const pending = provider.searchPlaces("Paris", 5);
    controller.abort();

    await expect(pending).rejects.toThrow("Transitous request timed out");
    await expect(pending).rejects.toBeInstanceOf(JourneyProviderUnavailableError);
    await expect(pending).rejects.not.toThrow("private provider diagnostics");
    expect(timeout).toHaveBeenCalledWith(20_000);
  });

  it("reports non-2xx responses without leaking the upstream body", async () => {
    const provider = new TransitousJourneyProvider(baseUrl, async () =>
      new Response("debug=/srv/transitous/private.ts raw-alert=<b>secret</b>", { status: 503 }), () => fixedNow);

    const pending = provider.searchPlaces("Paris", 5);

    await expect(pending).rejects.toThrow("Transitous returned 503");
    await expect(pending).rejects.toBeInstanceOf(JourneyProviderUnavailableError);
    await expect(pending).rejects.not.toThrow("private.ts");
  });
});
