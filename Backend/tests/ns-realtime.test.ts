import { describe, expect, it, vi } from "vitest";
import { TripSnapshotEnricher } from "../src/providers/platform-overlay.js";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { NSRealtimeOverlay } from "../src/providers/ns-realtime.js";

function trip(): TripSnapshot {
  return {
    id: "eu:transitous:ns-sprinter",
    source: "transitous",
    nativeId: "ns-sprinter",
    serviceDate: "2026-07-21",
    operatorName: "NS",
    product: "Sprinter",
    headsign: "Hoorn",
    fetchedAt: "2026-07-21T16:25:00.000Z",
    alertIds: [],
    stops: [{
      stationId: "eu:transitous:nl-sloterdijk",
      stationName: "Amsterdam Sloterdijk",
      countryCode: "NL",
      latitude: 52.388,
      longitude: 4.837,
      sequence: 2,
      scheduledArrival: "2026-07-21T16:31:00.000Z",
      scheduledDeparture: "2026-07-21T16:31:00.000Z",
      expectedArrival: "2026-07-21T16:31:00.000Z",
      expectedDeparture: "2026-07-21T16:31:00.000Z",
      plannedPlatform: "7",
      expectedPlatform: "7",
      platformSource: "Transitous",
      platformObservedAt: null,
      cancelled: false,
      passed: false,
    }],
  };
}

describe("NS realtime overlay", () => {
  it("maps arrival rows that have origin instead of direction", async () => {
    const snapshot = trip();
    snapshot.product = "Eurostar 9339";
    snapshot.headsign = "Amsterdam Centraal";
    snapshot.stops[0]!.scheduledDeparture = null;
    const overlay = overlayFor([{
      ...movement(), direction: undefined, origin: "Paris-Nord", name: "NS Int  9339",
      product: { number: "9339", longCategoryName: "Eurostar", type: "TRAIN" },
      actualDateTime: "2026-07-21T18:36:00+0200", actualTrack: "8",
      messages: [{ message: "Changed arrival track", style: "WARNING" }],
    }], "arrivals");

    expect(await overlay.platformUpdates(snapshot)).toEqual([expect.objectContaining({
      expectedPlatform: "8", expectedArrival: "2026-07-21T16:36:00.000Z", expectedDeparture: undefined,
    })]);
    expect(await overlay.tripAlertIds(snapshot)).toEqual([expect.stringMatching(/^ns:[0-9a-f]{8}$/u)]);
  });

  it.each([undefined, null, "", "   "])("does not reward absent direction %s when breaking a tie", async (direction) => {
    const overlay = overlayFor([
      { ...movement(), direction, actualTrack: "8" },
      { ...movement(), direction: "Haarlem", actualTrack: "9" },
    ]);
    expect(await overlay.platformUpdates(trip())).toEqual([]);
  });

  it("does not reward two empty destination labels or use arrival origin as destination evidence", async () => {
    const snapshot = trip();
    snapshot.headsign = "";
    expect(await overlayFor([
      { ...movement(), direction: "" }, { ...movement(), direction: "Hoorn" },
    ]).platformUpdates(snapshot)).toEqual([]);

    snapshot.headsign = "Hoorn";
    snapshot.stops[0]!.scheduledDeparture = null;
    expect(await overlayFor([
      { ...movement(), direction: undefined, origin: "Hoorn" },
      { ...movement(), direction: undefined, origin: "Haarlem" },
    ], "arrivals").platformUpdates(snapshot)).toEqual([]);
  });

  it("rejects empty product identity even when direction and time match", async () => {
    const snapshot = trip();
    snapshot.product = "  ";
    const overlay = overlayFor([{
      ...movement(), name: " ", product: { number: "", categoryCode: null, longCategoryName: "", type: "TRAIN" },
    }]);
    expect(await overlay.platformUpdates(snapshot)).toEqual([]);
  });

  it("keeps an exact numbered train ahead of a wrong-number category with a destination bonus", async () => {
    const snapshot = trip();
    snapshot.product = "Sprinter 4069";
    const wrong = { ...movement(), name: "NS 4071", actualTrack: "9",
      product: { number: "4071", longCategoryName: "Sprinter", type: "TRAIN" } };
    expect(await overlayFor([wrong]).platformUpdates(snapshot)).toEqual([]);
    const overlay = overlayFor([wrong, { ...movement(), direction: undefined, actualTrack: "8" }]);
    expect(await overlay.platformUpdates(snapshot)).toEqual([expect.objectContaining({ expectedPlatform: "8" })]);
  });

  it("requires a numbered train's exact identity when the row omits its number", async () => {
    const snapshot = trip();
    snapshot.product = "Sprinter 4069";
    expect(await overlayFor([{
      ...movement(), name: undefined, product: { longCategoryName: "Sprinter", type: "TRAIN" },
    }]).platformUpdates(snapshot)).toEqual([]);
    expect(await overlayFor([{
      ...movement(), name: "Sprinter 4069", product: { longCategoryName: "Sprinter", type: "TRAIN" },
    }]).platformUpdates(snapshot)).toHaveLength(1);
  });

  it("does not match a correct number outside the existing time window", async () => {
    const snapshot = trip();
    snapshot.product = "Sprinter 4069";
    expect(await overlayFor([{
      ...movement(), direction: undefined, plannedDateTime: "2026-07-21T18:42:00+0200",
    }]).platformUpdates(snapshot)).toEqual([]);
  });

  it("maps official expected time, changed track, cancellation, and messages", async () => {
    const requests: Request[] = [];
    const overlay = new NSRealtimeOverlay(
      "ns-key",
      "https://ns.test/api/v2",
      async (input, init) => {
        const request = new Request(input, init);
        requests.push(request);
        if (request.url.endsWith("/stations")) {
          return Response.json({ payload: [{
            UICCode: "8400059",
            code: "ASS",
            namen: { lang: "Amsterdam Sloterdijk", middel: "Sloterdijk", kort: "Sloterdijk" },
            lat: 52.388,
            lng: 4.837,
            land: "NL",
          }] });
        }
        return Response.json({ payload: { departures: [{
          direction: "Hoorn",
          name: "NS  4069",
          plannedDateTime: "2026-07-21T18:31:00+0200",
          actualDateTime: "2026-07-21T18:36:00+0200",
          plannedTrack: "7",
          actualTrack: "8",
          cancelled: true,
          messages: [{ message: "Extra overstap door werkzaamheden", style: "WARNING" }],
          product: {
            number: "4069",
            categoryCode: "SPR",
            shortCategoryName: "NS Sprinter",
            longCategoryName: "Sprinter",
            operatorName: "NS",
            type: "TRAIN",
          },
        }] } });
      },
      () => new Date("2026-07-21T16:26:00.000Z"),
    );

    expect(await overlay.platformUpdates(trip())).toEqual([expect.objectContaining({
      plannedPlatform: "7",
      expectedPlatform: "8",
      expectedDeparture: "2026-07-21T16:36:00.000Z",
      cancelled: true,
      source: "NS Reisinformatie",
    })]);
    expect(await overlay.tripAlertIds(trip())).toEqual([expect.stringMatching(/^ns:[0-9a-f]{8}$/u)]);
    expect(requests.filter((request) => request.url.endsWith("/stations"))).toHaveLength(1);
    expect(requests.filter((request) => request.url.includes("/departures?"))).toHaveLength(1);
    expect(requests.every((request) => request.headers.get("Ocp-Apim-Subscription-Key") === "ns-key")).toBe(true);
  });

  it("preserves the distinct intermediate arrival for the same resolved departure train", async () => {
    const snapshot = trip();
    snapshot.stops[0]!.scheduledArrival = "2026-07-21T16:29:00Z";
    const overlay = new NSRealtimeOverlay("key", "https://ns.test/api/v2", async (input) => {
      const path = String(input);
      if (path.endsWith("/stations")) return Response.json({ payload: [{ code: "ASS", land: "NL", lat: 52.388, lng: 4.837,
        namen: { lang: "Amsterdam Sloterdijk", middel: "Sloterdijk", kort: "Sloterdijk" } }] });
      if (path.includes("/arrivals?")) return Response.json({ payload: { arrivals: [
        { ...movement(), direction: null, origin: "Amsterdam", plannedDateTime: "2026-07-21T18:29:00+0200", actualDateTime: "2026-07-21T18:33:00+0200" },
        { ...movement(), product: { number: "4071", longCategoryName: "Sprinter", type: "TRAIN" }, plannedDateTime: "2026-07-21T18:29:00+0200", actualDateTime: "2026-07-21T18:50:00+0200" },
      ] } });
      return Response.json({ payload: { departures: [{ ...movement(), actualDateTime: "2026-07-21T18:36:00+0200", actualTrack: "8" }] } });
    });
    const result = await new TripSnapshotEnricher([overlay, overlay.arrivalOverlay]).enrich(snapshot);
    expect(result.stops[0]).toMatchObject({ expectedArrival: "2026-07-21T16:33:00.000Z", expectedDeparture: "2026-07-21T16:36:00.000Z", expectedPlatform: "8" });
  });

  it("keeps departure information when the supplementary arrival board stalls", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      const overlay = new NSRealtimeOverlay("key", "https://ns.test/api/v2", async (input) => {
        const path = String(input);
        if (path.endsWith("/stations")) return Response.json({ payload: [{ code: "ASS", land: "NL", lat: 52.388, lng: 4.837,
          namen: { lang: "Amsterdam Sloterdijk", middel: "Sloterdijk", kort: "Sloterdijk" } }] });
        if (path.includes("/arrivals?")) return new Promise<Response>(() => {});
        return Response.json({ payload: { departures: [{ ...movement(), actualDateTime: "2026-07-21T18:36:00+0200" }] } });
      });
      const result = await new TripSnapshotEnricher([overlay, overlay.arrivalOverlay], [], 20).enrich(trip());
      expect(result.stops[0]?.expectedDeparture).toBe("2026-07-21T16:36:00.000Z");
    } finally { error.mockRestore(); }
  });

  it("rejects an ambiguous same-time movement instead of guessing", async () => {
    const movement = {
      direction: "Hoorn",
      name: "NS  4069",
      plannedDateTime: "2026-07-21T18:31:00+0200",
      actualDateTime: "2026-07-21T18:31:00+0200",
      plannedTrack: "7",
      actualTrack: "7",
      cancelled: false,
      messages: [],
      product: { longCategoryName: "Sprinter", type: "TRAIN" },
    };
    const overlay = new NSRealtimeOverlay("ns-key", "https://ns.test/api/v2", async (input) => {
      if (String(input).endsWith("/stations")) return Response.json({ payload: [{
        UICCode: "8400059", code: "ASS",
        namen: { lang: "Amsterdam Sloterdijk", middel: "Sloterdijk", kort: "Sloterdijk" },
        lat: 52.388, lng: 4.837, land: "NL",
      }] });
      return Response.json({ payload: { departures: [movement, { ...movement }] } });
    });

    expect(await overlay.platformUpdates(trip())).toEqual([]);
  });
});

function movement() {
  return {
    direction: "Hoorn", name: "NS 4069", plannedDateTime: "2026-07-21T18:31:00+0200",
    plannedTrack: "7", actualTrack: "7", cancelled: false,
    product: { number: "4069", longCategoryName: "Sprinter", type: "TRAIN" },
  };
}

function overlayFor(movements: unknown[], kind: "arrivals" | "departures" = "departures"): NSRealtimeOverlay {
  return new NSRealtimeOverlay("ns-key", "https://ns.test/api/v2", async (input) => {
    if (String(input).endsWith("/stations")) return Response.json({ payload: [{
      UICCode: "8400059", code: "ASS",
      namen: { lang: "Amsterdam Sloterdijk", middel: "Sloterdijk", kort: "Sloterdijk" },
      lat: 52.388, lng: 4.837, land: "NL",
    }] });
    expect(String(input)).toContain(`/${kind}?`);
    return Response.json({ payload: { [kind]: movements } });
  }, () => new Date("2026-07-21T16:26:00.000Z"));
}
