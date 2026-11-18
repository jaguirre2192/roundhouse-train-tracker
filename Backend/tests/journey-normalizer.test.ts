import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";
import type { JourneyOptionSnapshot } from "../src/domain/journey.js";
import { normalizeJourneyOptions } from "../src/providers/journey-normalizer.js";
import { decodeRailPlaceId } from "../src/providers/rail-place-id.js";
import type {
  TransitousItinerary,
  TransitousLeg,
  TransitousPlanResponse,
} from "../src/providers/transitous-journey-types.js";

const context = {
  originKind: "station" as const,
  destinationKind: "station" as const,
  fetchedAt: "2026-07-21T19:00:00Z",
  attributions: ["Transitous", "OpenStreetMap contributors"],
};

async function fixture(name: string): Promise<TransitousPlanResponse> {
  return JSON.parse(await readFile(new URL(`fixtures/journeys/${name}`, import.meta.url), "utf8")) as TransitousPlanResponse;
}

function clone<T>(value: T): T {
  return structuredClone(value);
}

function firstRail(option: JourneyOptionSnapshot) {
  const segment = option.segments.find((candidate) => candidate.kind === "rail");
  if (segment?.kind !== "rail") throw new Error("Expected a rail segment");
  return segment.rail;
}

function nestedPlaceIds(option: JourneyOptionSnapshot): string[] {
  return option.segments.flatMap((segment) => segment.kind === "rail"
    ? [
        segment.rail.from.place.id,
        ...segment.rail.intermediateCalls.map((call) => call.place.id),
        segment.rail.to.place.id,
      ]
    : [segment.walk.from.id, segment.walk.to.id]);
}

function connectingPayload(source: TransitousPlanResponse): TransitousPlanResponse {
  const itinerary = source.itineraries.find((candidate) => candidate.legs.some((leg) => leg.mode === "WALK"));
  if (itinerary === undefined) throw new Error("Expected connecting fixture itinerary");
  return { itineraries: [clone(itinerary)] };
}

function walkLeg(payload: TransitousPlanResponse): TransitousLeg {
  const leg = payload.itineraries[0]?.legs.find((candidate) => candidate.mode === "WALK");
  if (leg === undefined) throw new Error("Expected a walk leg");
  return leg;
}

function directItinerary(payload: TransitousPlanResponse): TransitousItinerary {
  const itinerary = payload.itineraries.find((candidate) => candidate.legs.length === 1);
  if (itinerary === undefined) throw new Error("Expected a direct fixture itinerary");
  return clone(itinerary);
}

describe("normalizeJourneyOptions", () => {
  it("normalizes direct and connecting mainline journeys with the exact public segment shape", async () => {
    const options = normalizeJourneyOptions(await fixture("paris-amsterdam.json"), context);

    expect(options).toHaveLength(2);
    expect(options.map((option) => option.startTime)).toEqual([
      "2026-07-24T06:25:00Z",
      "2026-07-24T06:28:00Z",
    ]);
    expect(options[0]).toMatchObject({
      transferCount: 0,
      duration: 13_740,
      badges: ["direct", "fastest", "fewestChanges"],
      trackability: { trackableRailSegments: 1, totalRailSegments: 1 },
      realtimeFreshness: null,
      attributions: context.attributions,
      trackingToken: "",
    });
    expect(options[0]?.segments[0]).toMatchObject({
      kind: "rail",
      walk: null,
      rail: {
        tripId: "eu:transitous:20260724_08:25_fr-eurostar_9315",
        serviceDate: "2026-07-24",
        operatorName: "Eurostar",
        product: "Eurostar 9315",
        trainNumber: "9315",
        from: {
          scheduledDeparture: "2026-07-24T06:25:00Z",
          expectedDeparture: "2026-07-24T06:25:00Z",
          plannedPlatform: "7",
          expectedPlatform: "7",
        },
        to: { place: { id: expect.stringMatching(/^rail:transitous:station:/u) } },
        intermediateCalls: [{ place: { id: expect.stringMatching(/^rail:transitous:station:/u) } }],
        isTrackable: true,
        untrackableReason: null,
      },
    });
    expect(Object.keys(options[0]?.segments[0] ?? {}).sort()).toEqual(["id", "kind", "rail", "walk"]);
    expect(options[1]).toMatchObject({
      transferCount: 1,
      badges: [],
      trackability: { trackableRailSegments: 2, totalRailSegments: 2 },
      realtimeFreshness: context.fetchedAt,
    });
    expect(options[1]?.segments.map((segment) => segment.kind)).toEqual(["rail", "walk", "rail"]);
    expect(options[1]?.segments[1]).toMatchObject({
      kind: "walk",
      rail: null,
      walk: { duration: 180, distance: 120, isStationChange: true },
    });
    expect(options.flatMap(nestedPlaceIds).map(decodeRailPlaceId).every((place) =>
      place.provider === "transitous" && place.kind === "station")).toBe(true);
    const direct = firstRail(options[0]!);
    expect([
      direct.from.place.id,
      ...direct.intermediateCalls.map((call) => call.place.id),
      direct.to.place.id,
    ].map((id) => decodeRailPlaceId(id).nativeId)).toEqual([
      "fr-eurostar_paris_nord",
      "fr-eurostar_bruxelles_midi_3",
      "fr-eurostar_amsterdam_centraal",
    ]);
  });

  it("normalizes Amtrak regional rail through the existing mainline scope", async () => {
    const options = normalizeJourneyOptions(await fixture("new-york-washington.json"), context);

    expect(options.map((option) => firstRail(option).trainNumber)).toEqual(["141", "2109"]);
    expect(options[0]?.badges).toEqual(["direct", "fewestChanges"]);
    expect(options[1]?.badges).toEqual(["direct", "fastest", "fewestChanges"]);
    expect(options.every((option) => firstRail(option).isTrackable)).toBe(true);
    expect(firstRail(options[1]!).from.place.countryCode).toBe("US");
    expect(firstRail(options[1]!).intermediateCalls).toHaveLength(2);
  });

  it("default-denies urban rail, buses, unknown route types, and regional urban identities", async () => {
    const payload = await fixture("filter-cases.json");
    const accepted = directItinerary(payload);
    const unknown = clone(accepted);
    unknown.id = "unknown-route-type";
    unknown.legs[0]!.routeType = 999;
    const urbanIdentity = clone(accepted);
    urbanIdentity.id = "urban-feed-identity";
    urbanIdentity.legs[0]!.mode = "REGIONAL_RAIL";
    urbanIdentity.legs[0]!.routeType = 2;
    urbanIdentity.legs[0]!.tripId = "20260724_fr-idf_IDFM:RER-A";
    urbanIdentity.legs[0]!.from.stopId = "fr-idf_IDFM:origin";
    urbanIdentity.legs[0]!.to.stopId = "fr-idf_IDFM:destination";
    const prohibited = payload.itineraries.filter((candidate) =>
      ["reject-urban-rer", "reject-bus-only"].includes(candidate.id ?? ""));

    expect(normalizeJourneyOptions({ itineraries: [...prohibited, unknown, urbanIdentity] }, context)).toEqual([]);
  });

  it("rejects a known urban trip identity even when its mode claims long-distance rail", async () => {
    const urbanIdentity = directItinerary(await fixture("filter-cases.json"));
    urbanIdentity.id = "urban-trip-disguised-as-long-distance";
    urbanIdentity.legs[0]!.mode = "LONG_DISTANCE";
    urbanIdentity.legs[0]!.routeType = 102;
    urbanIdentity.legs[0]!.tripId = "20260724_fr-idf_IDFM:RER-A";

    expect(normalizeJourneyOptions({ itineraries: [urbanIdentity] }, context)).toEqual([]);
  });

  it("accepts only the supported generic and extended mainline route types", async () => {
    const base = directItinerary(await fixture("filter-cases.json"));
    const cases = [
      { routeType: 2, mode: "REGIONAL_RAIL" },
      { routeType: 101, mode: "HIGHSPEED_RAIL" },
      { routeType: 102, mode: "LONG_DISTANCE" },
      { routeType: 103, mode: "LONG_DISTANCE" },
      { routeType: 105, mode: "NIGHT_RAIL" },
      { routeType: 106, mode: "REGIONAL_RAIL" },
    ];
    const itineraries = cases.map(({ routeType, mode }, index) => {
      const itinerary = clone(base);
      itinerary.id = `accepted-route-${routeType}`;
      itinerary.startTime = `2026-07-25T0${index}:00:00Z`;
      itinerary.endTime = `2026-07-25T0${index + 1}:00:00Z`;
      itinerary.duration = 3600;
      Object.assign(itinerary.legs[0]!, {
        mode,
        routeType,
        startTime: itinerary.startTime,
        endTime: itinerary.endTime,
        scheduledStartTime: itinerary.startTime,
        scheduledEndTime: itinerary.endTime,
        tripId: `20260725_nl-openov_mainline_${index}`,
      });
      Object.assign(itinerary.legs[0]!.from, {
        departure: itinerary.startTime,
        scheduledDeparture: itinerary.startTime,
      });
      Object.assign(itinerary.legs[0]!.to, {
        arrival: itinerary.endTime,
        scheduledArrival: itinerary.endTime,
      });
      return itinerary;
    });

    expect(normalizeJourneyOptions({ itineraries }, context)).toHaveLength(cases.length);
  });

  it("allows transfer walks at both caps and rejects either cap when exceeded", async () => {
    const source = await fixture("paris-amsterdam.json");
    const atCaps = connectingPayload(source);
    Object.assign(walkLeg(atCaps), { duration: 1_800, distance: 5_000 });
    const overDuration = clone(atCaps);
    walkLeg(overDuration).duration = 1_801;
    const overDistance = clone(atCaps);
    walkLeg(overDistance).distance = 5_001;

    expect(normalizeJourneyOptions(atCaps, context)).toHaveLength(1);
    expect(normalizeJourneyOptions(overDuration, context)).toEqual([]);
    expect(normalizeJourneyOptions(overDistance, context)).toEqual([]);
  });

  it("removes bounded city access and egress walks but rejects them for exact-station searches", async () => {
    const source = directItinerary(await fixture("paris-amsterdam.json"));
    const rail = source.legs[0]!;
    const access: TransitousLeg = {
      mode: "WALK",
      routeType: null,
      from: { name: "Paris", lat: 48.853495, lon: 2.348392, tz: "Europe/Paris" },
      to: clone(rail.from),
      startTime: "2026-07-24T06:15:00Z",
      endTime: rail.startTime,
      duration: 600,
      distance: 2_000,
    };
    const egress: TransitousLeg = {
      mode: "WALK",
      routeType: null,
      from: clone(rail.to),
      to: { name: "Amsterdam", lat: 52.3676, lon: 4.9041, tz: "Europe/Amsterdam" },
      startTime: rail.endTime,
      endTime: "2026-07-24T10:24:00Z",
      duration: 600,
      distance: 1_500,
    };
    source.legs = [access, rail, egress];
    source.startTime = access.startTime;
    source.endTime = egress.endTime;
    source.duration = 14_940;
    const payload = { itineraries: [source] };

    const cityOptions = normalizeJourneyOptions(payload, {
      ...context,
      originKind: "city",
      destinationKind: "city",
    });
    expect(cityOptions).toHaveLength(1);
    expect(cityOptions[0]?.segments.map((segment) => segment.kind)).toEqual(["rail"]);
    expect(cityOptions[0]).toMatchObject({
      startTime: rail.startTime,
      endTime: rail.endTime,
      duration: rail.duration,
    });
    expect(normalizeJourneyOptions(payload, context)).toEqual([]);
  });

  it("collapses zero-distance station aliases while retaining the rail connection", async () => {
    const payload = connectingPayload(await fixture("paris-amsterdam.json"));
    const walk = walkLeg(payload);
    walk.duration = 0;
    walk.distance = 0;
    walk.endTime = walk.startTime;

    const options = normalizeJourneyOptions(payload, context);

    expect(options).toHaveLength(1);
    expect(options[0]?.segments.map((segment) => segment.kind)).toEqual(["rail", "rail"]);
    expect(options[0]?.transferCount).toBe(1);
  });

  it("collapses a positive-duration zero-distance alias so same-trip rail can merge", async () => {
    const payload = await fixture("filter-cases.json");
    const itinerary = payload.itineraries.find((candidate) => candidate.id === "merge-adjacent-same-trip");
    if (itinerary === undefined || itinerary.legs.length !== 2) throw new Error("Expected split same-trip fixture");
    const split = clone(itinerary);
    const first = split.legs[0]!;
    const second = split.legs[1]!;
    const alias: TransitousLeg = {
      mode: "WALK",
      routeType: null,
      from: clone(first.to),
      to: clone(second.from),
      startTime: first.endTime,
      endTime: second.startTime,
      duration: 120,
      distance: 0,
    };
    split.legs = [first, alias, second];

    const options = normalizeJourneyOptions({ itineraries: [split] }, context);

    expect(options).toHaveLength(1);
    expect(options[0]?.segments.map((segment) => segment.kind)).toEqual(["rail"]);
    expect(options[0]?.transferCount).toBe(0);
    expect(firstRail(options[0]!).intermediateCalls).toEqual([
      expect.objectContaining({ place: expect.objectContaining({ displayName: "Utrecht Centraal" }) }),
    ]);
  });

  it("merges adjacent legs of one trip and deduplicates canonical journeys", async () => {
    const options = normalizeJourneyOptions(await fixture("filter-cases.json"), context);

    expect(options).toHaveLength(2);
    expect(options.map((option) => option.startTime)).toEqual([
      "2026-07-24T06:30:00Z",
      "2026-07-24T10:00:00Z",
    ]);
    expect(options[0]?.segments).toHaveLength(1);
    expect(options[0]).toMatchObject({ transferCount: 0, badges: ["direct", "fastest", "fewestChanges"] });
    expect(firstRail(options[0]!).from.place.displayName).toBe("Amsterdam Centraal");
    expect(firstRail(options[0]!).to.place.displayName).toBe("Arnhem Centraal");
    expect(firstRail(options[0]!).intermediateCalls).toEqual([
      expect.objectContaining({
        place: expect.objectContaining({ displayName: "Utrecht Centraal" }),
        scheduledArrival: "2026-07-24T06:57:00Z",
        scheduledDeparture: "2026-07-24T06:59:00Z",
      }),
    ]);
    expect(options[1]?.badges).toEqual(["direct", "fewestChanges"]);
  });

  it("keeps fingerprints stable across provider IDs, order, live fields, and fetch time", async () => {
    const source = await fixture("paris-amsterdam.json");
    const original = directItinerary(source);
    const changed = clone(original);
    changed.id = "different-provider-itinerary-id";
    changed.startTime = "2026-07-24T06:33:00Z";
    changed.endTime = "2026-07-24T10:22:00Z";
    changed.legs[0]!.startTime = changed.startTime;
    changed.legs[0]!.endTime = changed.endTime;
    changed.legs[0]!.from.departure = changed.startTime;
    changed.legs[0]!.from.track = "99";
    changed.legs[0]!.to.arrival = changed.endTime;
    const stable = normalizeJourneyOptions({ itineraries: [original] }, context)[0]!;
    const reordered = normalizeJourneyOptions({ itineraries: [changed, original] }, {
      ...context,
      fetchedAt: "2026-07-22T00:00:00Z",
    });

    expect(reordered).toHaveLength(1);
    expect(reordered[0]?.fingerprint).toBe(stable.fingerprint);
    expect(reordered[0]?.fingerprint).not.toContain(original.id ?? "");

    const unscheduled = clone(original);
    delete unscheduled.legs[0]!.scheduledStartTime;
    delete unscheduled.legs[0]!.from.scheduledDeparture;
    const delayedUnscheduled = clone(unscheduled);
    delayedUnscheduled.startTime = "2026-07-24T06:40:00Z";
    delayedUnscheduled.legs[0]!.startTime = delayedUnscheduled.startTime;
    delayedUnscheduled.legs[0]!.from.departure = delayedUnscheduled.startTime;
    const firstUnscheduled = normalizeJourneyOptions({ itineraries: [unscheduled] }, context)[0]!;
    const secondUnscheduled = normalizeJourneyOptions({ itineraries: [delayedUnscheduled] }, context)[0]!;
    expect(secondUnscheduled.fingerprint).toBe(firstUnscheduled.fingerprint);
  });

  it("keeps accepted rail without a trip ID visible but explicitly untrackable", async () => {
    const itinerary = directItinerary(await fixture("filter-cases.json"));
    itinerary.legs[0]!.tripId = null;

    const options = normalizeJourneyOptions({ itineraries: [itinerary] }, context);

    expect(options).toHaveLength(1);
    expect(firstRail(options[0]!)).toMatchObject({
      tripId: null,
      isTrackable: false,
      untrackableReason: "No stable train identity",
    });
    expect(options[0]?.trackability).toEqual({ trackableRailSegments: 0, totalRailSegments: 1 });
  });
});
