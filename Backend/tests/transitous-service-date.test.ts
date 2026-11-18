import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";
import { normalizeJourneyOptions } from "../src/providers/journey-normalizer.js";
import { TransitousProvider } from "../src/providers/transitous.js";
import { transitousServiceDate } from "../src/providers/transitous-service-date.js";
import type { TransitousPlanResponse } from "../src/providers/transitous-journey-types.js";

// Intercités de nuit Paris Austerlitz 21:04 → Latour-de-Carol, boarded at Ax-les-Thermes
// at 03:15 CEST on the 22nd (01:15Z). Its GTFS start date is still the 21st.
const nightTrainId = "20260721_21:04_fr-horaires-sncf_OCESN3971F3384113";
const nightTrainBoarding = {
  name: "Ax-les-Thermes",
  stopId: "fr-horaires-sncf_StopPoint:OCEINTERCITES-87611236",
  lat: 42.72,
  lon: 1.84,
  tz: "Europe/Paris",
  scheduledDeparture: "2026-07-22T01:15:00Z",
  departure: "2026-07-22T01:15:00Z",
};

// A train leaving Paris at 00:30 CEST on the 22nd is 22:30Z on the 21st.
const earlyTrainId = "20260722_00:30_fr-horaires-sncf_OCESN4021F1";
const earlyTrainOrigin = {
  name: "Paris Gare de Lyon",
  stopId: "fr-horaires-sncf_StopPoint:OCETGV-87686006",
  lat: 48.84,
  lon: 2.37,
  tz: "Europe/Paris",
  scheduledDeparture: "2026-07-21T22:30:00Z",
  departure: "2026-07-21T22:30:00Z",
};

function boardProvider(stopTimes: unknown[]): TransitousProvider {
  return new TransitousProvider("https://example.test", async () => Response.json({ stopTimes }));
}

describe("Transitous service date", () => {
  it("keeps an overnight train's origin date when it is boarded after midnight", async () => {
    const board = await boardProvider([
      { place: nightTrainBoarding, mode: "NIGHT_RAIL", tripId: nightTrainId, headsign: "Latour-de-Carol" },
    ]).fetchBoard({
      stationId: "eu:transitous:fr-horaires-sncf_StopPoint:OCEINTERCITES-87611236",
      source: "transitous",
      nativeId: "fr-horaires-sncf_StopPoint:OCEINTERCITES-87611236",
      at: "2026-07-22T01:00:00Z",
      direction: "departures",
    });

    expect(board[0]?.trip.serviceDate).toBe("2026-07-21");
  });

  it("uses the local date of a train departing 00:30 in summer, not its UTC date", async () => {
    const board = await boardProvider([
      { place: earlyTrainOrigin, mode: "HIGHSPEED_RAIL", tripId: earlyTrainId, headsign: "Marseille" },
    ]).fetchBoard({
      stationId: "eu:transitous:fr-horaires-sncf_StopPoint:OCETGV-87686006",
      source: "transitous",
      nativeId: "fr-horaires-sncf_StopPoint:OCETGV-87686006",
      at: "2026-07-21T22:00:00Z",
      direction: "departures",
    });

    expect(board[0]?.trip.serviceDate).toBe("2026-07-22");
  });

  it("falls back to the stop's local date when the trip id carries no usable date", () => {
    expect(transitousServiceDate("trip-without-date", earlyTrainOrigin, "2026-07-21T22:00:00Z")).toBe("2026-07-22");
    expect(transitousServiceDate("20261341_00:30_fr-x_1", earlyTrainOrigin, "2026-07-21T22:00:00Z")).toBe("2026-07-22");
  });

  it("stamps journey rail segments with the trip's origin date", async () => {
    const payload = JSON.parse(await readFile(
      new URL("fixtures/journeys/paris-amsterdam.json", import.meta.url),
      "utf8",
    )) as TransitousPlanResponse;
    const itinerary = structuredClone(payload.itineraries.find((candidate) => candidate.legs.length === 1)!);
    const leg = itinerary.legs[0]!;
    leg.tripId = earlyTrainId;
    leg.from = { ...leg.from, tz: "Europe/Paris", scheduledDeparture: "2026-07-21T22:30:00Z", departure: "2026-07-21T22:30:00Z" };
    leg.startTime = "2026-07-21T22:30:00Z";
    leg.scheduledStartTime = "2026-07-21T22:30:00Z";

    const options = normalizeJourneyOptions({ itineraries: [itinerary] }, {
      originKind: "station",
      destinationKind: "station",
      fetchedAt: "2026-07-21T19:00:00Z",
      attributions: [],
    });
    const segment = options[0]?.segments[0];

    expect(segment?.kind === "rail" ? segment.rail.serviceDate : null).toBe("2026-07-22");
  });
});

describe("Transitous station board", () => {
  const place = (stopId: string, time: string) => ({
    name: "Berlin Hbf",
    stopId,
    lat: 52.52,
    lon: 13.37,
    tz: "Europe/Berlin",
    scheduledArrival: time,
    arrival: time,
    scheduledDeparture: null,
    departure: null,
  });

  it("keeps the board when one sibling stop id fails and fails only when all do", async () => {
    const provider = new TransitousProvider("https://example.test", async (input) => {
      const stopId = new URL(String(input)).searchParams.get("stopId");
      if (stopId === "de-broken") return new Response("upstream error", { status: 502 });
      return Response.json({ stopTimes: [
        { place: place("de-hbf-upper", "2026-07-21T08:10:00Z"), mode: "HIGHSPEED_RAIL", tripId: "20260721_06:00_de-db_ice-1", headsign: "Berlin" },
      ] });
    });
    const reference = {
      stationId: "eu:transitous:de-hbf",
      source: "transitous" as const,
      nativeId: "de-hbf-upper|de-broken",
      at: "2026-07-21T08:00:00Z",
      direction: "departures" as const,
    };

    await expect(provider.fetchBoard(reference)).resolves.toHaveLength(1);
    await expect(provider.fetchBoard({ ...reference, nativeId: "de-broken|de-broken" }))
      .rejects.toThrow("Transitous returned 502");
  });

  it("orders an arrivals board by arrival time", async () => {
    const provider = boardProvider([
      { place: { ...place("de-hbf", "2026-07-21T08:20:00Z"), departure: "2026-07-21T08:05:00Z" }, mode: "HIGHSPEED_RAIL", tripId: "20260721_06:00_de-db_ice-late", headsign: "Berlin" },
      { place: { ...place("de-hbf", "2026-07-21T08:10:00Z"), departure: "2026-07-21T08:15:00Z" }, mode: "HIGHSPEED_RAIL", tripId: "20260721_06:00_de-db_ice-early", headsign: "Berlin" },
    ]);

    const board = await provider.fetchBoard({
      stationId: "eu:transitous:de-hbf",
      source: "transitous",
      nativeId: "de-hbf",
      at: "2026-07-21T08:00:00Z",
      direction: "arrivals",
    });

    expect(board.map((entry) => entry.trip.nativeId)).toEqual([
      "20260721_06:00_de-db_ice-early",
      "20260721_06:00_de-db_ice-late",
    ]);
  });
});
