import { describe, expect, it, vi } from "vitest";
import { transit_realtime } from "gtfs-realtime-bindings";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { SwissRealtimeOverlay } from "../src/providers/swiss-realtime.js";

function trip(): TripSnapshot {
  return {
    id: "eu:transitous:swiss-ic1",
    source: "transitous",
    nativeId: "20260721_17:07_ch-opentransportdataswiss26_.ojp-91-1-D.1.TA.2345.j26",
    serviceDate: "2026-07-21",
    operatorName: "SBB",
    product: "IC1",
    headsign: "Genève-Aéroport",
    fetchedAt: "2026-07-21T16:20:00.000Z",
    alertIds: [],
    stops: [{
      stationId: "eu:transitous:ch-opentransportdataswiss26_ch:1:sloid:3000:500:32",
      stationName: "Zürich HB",
      countryCode: "CH",
      latitude: 47.378,
      longitude: 8.54,
      sequence: 9,
      scheduledArrival: "2026-07-21T16:22:00.000Z",
      scheduledDeparture: "2026-07-21T16:32:00.000Z",
      expectedArrival: "2026-07-21T16:22:00.000Z",
      expectedDeparture: "2026-07-21T16:32:00.000Z",
      plannedPlatform: "32",
      expectedPlatform: "32",
      platformSource: "Transitous",
      platformObservedAt: null,
      cancelled: false,
      passed: false,
    }, {
      stationId: "eu:transitous:ch-opentransportdataswiss26_ch:1:sloid:7000:3:6",
      stationName: "Bern",
      countryCode: "CH",
      latitude: 46.949,
      longitude: 7.439,
      sequence: 10,
      scheduledArrival: "2026-07-21T17:28:00.000Z",
      scheduledDeparture: "2026-07-21T17:34:00.000Z",
      expectedArrival: "2026-07-21T17:28:00.000Z",
      expectedDeparture: "2026-07-21T17:34:00.000Z",
      plannedPlatform: "6",
      expectedPlatform: "6",
      platformSource: "Transitous",
      platformObservedAt: null,
      cancelled: false,
      passed: false,
    }],
  };
}

function response(entity: transit_realtime.IFeedEntity): Response {
  const feed = transit_realtime.FeedMessage.create({
    header: { gtfsRealtimeVersion: "2.0", timestamp: 1_784_651_507 },
    entity: [entity],
  });
  const bytes = transit_realtime.FeedMessage.encode(feed).finish();
  return new Response(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer);
}

describe("Swiss GTFS-RT overlay", () => {
  it("matches across a static feed-version trip-id change and maps platforms and delays", async () => {
    const requests: Request[] = [];
    const overlay = new SwissRealtimeOverlay("swiss-token", "https://swiss.test/gtfs-rt", async (input, init) => {
      requests.push(new Request(input, init));
      return response({
        id: "current-ic1",
        tripUpdate: {
          trip: {
            tripId: ".ojp-91-1-D.1.TA.2365.j26",
            startTime: "17:07:00",
            startDate: "20260721",
            scheduleRelationship: transit_realtime.TripDescriptor.ScheduleRelationship.SCHEDULED,
          },
          stopTimeUpdate: [{
            stopSequence: 9,
            stopId: "ch:1:sloid:3000_gen:ch:1:sloid:3000:500:31_pf:31",
            departure: { delay: 60 },
          }, {
            stopSequence: 11,
            stopId: "ch:1:sloid:7000_gen:ch:1:sloid:7000:3:6_pf:6",
            arrival: { delay: 30 },
            departure: { delay: 30 },
          }],
        },
      });
    });

    expect(await overlay.platformUpdates(trip())).toEqual(expect.arrayContaining([
      expect.objectContaining({
        stationId: expect.stringContaining("sloid:3000"),
        plannedPlatform: "32",
        expectedPlatform: "31",
        expectedDeparture: "2026-07-21T16:33:00.000Z",
      }),
      expect.objectContaining({
        stationId: expect.stringContaining("sloid:7000"),
        expectedPlatform: "6",
        expectedArrival: "2026-07-21T17:28:30.000Z",
      }),
    ]));
    expect(requests).toHaveLength(1);
    expect(requests[0]?.headers.get("authorization")).toBe("Bearer swiss-token");
  });

  it("maps a whole-trip cancellation for an exact trip id", async () => {
    const overlay = new SwissRealtimeOverlay("swiss-token", "https://swiss.test/gtfs-rt", async () => response({
      id: "cancelled-ic1",
      tripUpdate: {
        trip: {
          tripId: ".ojp-91-1-D.1.TA.2345.j26",
          startTime: "17:07:00",
          startDate: "20260721",
          scheduleRelationship: transit_realtime.TripDescriptor.ScheduleRelationship.CANCELED,
        },
        stopTimeUpdate: [],
      },
    }));

    expect(await overlay.platformUpdates(trip())).toEqual([
      expect.objectContaining({ stopSequence: 9, cancelled: true }),
      expect.objectContaining({ stopSequence: 10, cancelled: true }),
    ]);
  });
});


describe("Swiss migrated platform identities", () => {
  function overlay(stopId: string, startDate = "20260721") {
    return new SwissRealtimeOverlay("token", "https://swiss.test/gtfs-rt", async () => response({
      id: "exact",
      tripUpdate: {
        trip: { tripId: ".ojp-91-1-D.1.TA.2345.j26", startDate },
        stopTimeUpdate: [{ stopId, arrival: { delay: 120 } }],
      },
    }));
  }

  it.each([
    ["ch:1:sloid:7000_gen:ch:1:sloid:7000:0:349752_pf:2A-D", "2A-D"],
    ["ch:1:sloid:7000_gen:ch:1:sloid:7000:0:11_pf:11.12", null],
    ["ch:1:sloid:7000_gen:missingSLOID_pf:6", "6"],
  ])("preserves explicit platform codes from %s", async (id, platform) => {
    expect(await overlay(id).platformUpdates(trip())).toEqual([
      expect.objectContaining({ stopSequence: 10, expectedPlatform: platform, expectedArrival: "2026-07-21T17:30:00.000Z" }),
    ]);
  });

  it("does not turn a quay identifier into a platform", async () => {
    expect(await overlay("ch:1:sloid:7000:0:99").platformUpdates(trip())).toEqual([
      expect.objectContaining({ stopSequence: 10, expectedPlatform: null }),
    ]);
  });

  it("rejects a different service date and a station with a shared numeric prefix", async () => {
    expect(await overlay("ch:1:sloid:7000:3:6", "20260720").platformUpdates(trip())).toEqual([]);
    expect(await overlay("ch:1:sloid:700:3:6").platformUpdates(trip())).toEqual([]);
  });
});

describe("Swiss static-label overlay regressions", () => {
  const dictionary = { feedVersion: "20261111", startDate: "20251214", endDate: "20261212", platforms: new Map([
    ["ch:1:sloid:7000_gen:ch:1:sloid:7000:0:349752_pf:3.4", "3/4"],
    ["ch:1:sloid:7000:0:349752", "2A-D"],
  ]) };
  function fixture(stopId: string, snapshot = trip(), lookupFails = false) {
    const overlay = new SwissRealtimeOverlay("token", "https://swiss.test/gtfs-rt", async () => response({
      id: "exact",
      tripUpdate: {
        trip: { tripId: ".ojp-91-1-D.1.TA.2345.j26", startDate: snapshot.serviceDate.replaceAll("-", "") },
        stopTimeUpdate: [{ stopId, arrival: { delay: 120 } }],
      },
    }), () => new Date("2026-11-13T21:04:52Z"), {
      async load() { if (lookupFails) throw new Error("Static source unavailable"); return dictionary; },
    });
    return overlay.platformUpdates(snapshot);
  }

  it("maps dotted encodings and plain SLOID quays only through exact authoritative labels", async () => {
    expect(await fixture("ch:1:sloid:7000_gen:ch:1:sloid:7000:0:349752_pf:3.4")).toEqual([
      expect.objectContaining({ expectedPlatform: "3/4", expectedArrival: "2026-07-21T17:30:00.000Z" }),
    ]);
    expect(await fixture("ch:1:sloid:7000:0:349752")).toEqual([expect.objectContaining({ expectedPlatform: "2A-D" })]);
    expect(await fixture("ch:1:sloid:7000:0:349753")).toEqual([expect.objectContaining({ expectedPlatform: null })]);
  });

  it("retains delay data when the static source fails", async () => {
    expect(await fixture("ch:1:sloid:7000:0:349752", trip(), true)).toEqual([
      expect.objectContaining({ expectedPlatform: null, expectedArrival: "2026-07-21T17:30:00.000Z" }),
    ]);
  });

  it("rejects repeated visits rather than assigning a station-level update to either visit", async () => {
    const snapshot = trip(); snapshot.stops.push({ ...snapshot.stops[1]!, sequence: 11 });
    expect(await fixture("ch:1:sloid:7000:0:349752", snapshot)).toEqual([]);
  });

  it("does not apply Swiss feed observations to foreign stops outside its supported scope", async () => {
    const snapshot = trip(); snapshot.stops[1]!.countryCode = "DE";
    expect(await fixture("ch:1:sloid:7000:0:349752", snapshot)).toEqual([]);
  });

  it("supports exact Didok station identities for Liechtenstein without matching numeric prefixes", async () => {
    const snapshot = trip();
    snapshot.stops[1] = { ...snapshot.stops[1]!, countryCode: "LI", stationId: "eu:transitous:ch-opentransportdataswiss26_8101243" };
    expect(await fixture("8101243_gen:missingSLOID_pf:1", snapshot)).toEqual([expect.objectContaining({ expectedPlatform: "1" })]);
    expect(await fixture("810124_gen:missingSLOID_pf:1", snapshot)).toEqual([]);
  });

  it("does not bypass serviceDate via the native departure-date fallback", async () => {
    const snapshot = trip(); snapshot.serviceDate = "2026-07-22";
    const overlay = new SwissRealtimeOverlay("token", "https://swiss.test/gtfs-rt", async () => response({
      id: "fallback", tripUpdate: {
        trip: { tripId: ".ojp-91-1-D.1.TA.9999.j26", startTime: "17:07:00", startDate: "20260721" },
        stopTimeUpdate: [{ stopId: "ch:1:sloid:3000:500:31" }, { stopId: "ch:1:sloid:7000:3:6" }],
      },
    }));
    expect(await overlay.platformUpdates(snapshot)).toEqual([]);
  });
});

describe("Swiss cache warming", () => {
  it("prefetches only a relevant Swiss reference with unresolved platform IDs", async () => {
    let feedCalls = 0, staticCalls = 0;
    const overlay = new SwissRealtimeOverlay("token", "https://swiss.test/gtfs-rt", async () => {
      feedCalls += 1;
      return response({ id: "exact", tripUpdate: {
        trip: { tripId: ".ojp-91-1-D.1.TA.2345.j26", startDate: "20260721" },
        stopTimeUpdate: [{ stopId: "ch:1:sloid:7000:0:349752" }],
      } });
    }, () => new Date(), { async load() { staticCalls += 1; return null; } });
    const reference = trip();
    await overlay.prefetch({ ...reference, nativeId: "20260721_17:07_at-railway_other" });
    expect(feedCalls).toBe(0);
    await overlay.prefetch({ ...reference, serviceDate: "2026-07-22" });
    expect(feedCalls).toBe(0);
    await overlay.prefetch(reference);
    expect(feedCalls).toBe(1); expect(staticCalls).toBe(1);
    await overlay.platformUpdates(reference);
    expect(feedCalls).toBe(1);
  });

  it("returns delays within the overlay budget while a cold static lookup keeps warming", async () => {
    vi.useFakeTimers();
    try {
      const overlay = new SwissRealtimeOverlay("token", "https://swiss.test/gtfs-rt", async () => response({
        id: "exact", tripUpdate: {
          trip: { tripId: ".ojp-91-1-D.1.TA.2345.j26", startDate: "20260721" },
          stopTimeUpdate: [{ stopId: "ch:1:sloid:7000:0:349752", arrival: { delay: 120 } }],
        },
      }), () => new Date(), { load: () => new Promise(() => {}) });
      const work = overlay.platformUpdates(trip());
      await vi.advanceTimersByTimeAsync(250);
      expect(await work).toEqual([expect.objectContaining({ expectedPlatform: null, expectedArrival: "2026-07-21T17:30:00.000Z" })]);
    } finally { vi.useRealTimers(); }
  });
});
