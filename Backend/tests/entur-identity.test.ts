import { describe, expect, it } from "vitest";
import type { StopSnapshot, TripSnapshot } from "../src/domain/snapshot.js";
import { EnturPlatformOverlay } from "../src/providers/entur.js";

const journeyId = "VYG:ServiceJourney:1517_443161-R";
const oppositeJourneyId = "VYG:ServiceJourney:1514-SKI_753034-R";

function snapshot(stop: Partial<StopSnapshot> = {}): TripSnapshot {
  return {
    id: `eu:transitous:20261113_09:06_no-Entur_${journeyId}`,
    source: "transitous",
    nativeId: `20261113_09:06_no-Entur_${journeyId}`,
    serviceDate: "2026-11-13",
    operatorName: "Vy",
    product: "R23",
    headsign: "Ski",
    fetchedAt: "2026-11-13T08:05:01.030Z",
    alertIds: [],
    stops: [{
      stationId: "eu:transitous:no-Entur_NSR:Quay:201",
      stationName: "Ski stasjon",
      countryCode: "NO",
      latitude: 59.718533,
      longitude: 10.833826,
      sequence: 2,
      scheduledArrival: "2026-11-13T08:17:00Z",
      scheduledDeparture: null,
      expectedArrival: "2026-11-13T08:17:00Z",
      expectedDeparture: null,
      plannedPlatform: "2",
      expectedPlatform: "2",
      platformSource: "Transitous",
      platformObservedAt: null,
      cancelled: false,
      passed: false,
      ...stop,
    }],
  };
}

// Exact target call returned by the official arrivals board on 2026-11-13.
// Further tests deliberately vary individual fields to test rejection boundaries.
function targetCall() {
  return {
    date: "2026-11-13",
    aimedArrivalTime: "2026-11-13T09:17:00+01:00",
    aimedDepartureTime: "2026-11-13T09:17:00+01:00",
    expectedArrivalTime: "2026-11-13T09:17:00+01:00",
    expectedDepartureTime: "2026-11-13T09:17:00+01:00",
    realtime: false,
    cancellation: false,
    destinationDisplay: { frontText: "Ski" },
    quay: { id: "NSR:Quay:201", publicCode: "2" },
    serviceJourney: { id: journeyId },
  };
}

function harness(calls: unknown[]) {
  const requests: Request[] = [];
  const overlay = new EnturPlatformOverlay(
    "https://example.test/geocoder",
    "https://example.test/graphql",
    async (input, init) => {
      const request = new Request(input, init);
      requests.push(request);
      if (request.url.includes("geocoder")) {
        return Response.json({ features: [{ properties: {
          id: "NSR:StopPlace:60944",
          names: { default: "Ski stasjon" },
          address: { countryCode: "NO" },
        } }] });
      }
      return Response.json({ data: { stopPlace: { estimatedCalls: calls } } });
    },
    () => new Date("2026-11-13T08:05:01.030Z"),
  );
  return { overlay, requests };
}

describe("Entur service and call identity", () => {
  it("rejects the captured cancelled R23 in the opposite direction", async () => {
    // Original wrong-service response at Ski, captured at 08:15 UTC. The old
    // line/45-minute matcher borrowed this cancellation and both 07:38Z times.
    const wrongCall = {
      aimedArrivalTime: "2026-11-13T08:38:00+01:00",
      aimedDepartureTime: "2026-11-13T08:38:00+01:00",
      expectedArrivalTime: "2026-11-13T08:38:00+01:00",
      expectedDepartureTime: "2026-11-13T08:38:00+01:00",
      realtime: true,
      cancellation: true,
      destinationDisplay: { frontText: "Oslo S" },
      quay: { id: "NSR:Quay:201", publicCode: "2" },
      serviceJourney: {
        id: oppositeJourneyId,
        journeyPattern: { line: { id: "VYG:Line:R23", publicCode: "R23", name: "Stabekk-Oslo S-Moss" } },
      },
    };
    const { overlay } = harness([wrongCall]);

    expect(await overlay.platformUpdates(snapshot())).toEqual([]);
    // Supplying the new date field cannot make this different service eligible.
    expect(await harness([{ ...wrongCall, date: "2026-11-13" }]).overlay.platformUpdates(snapshot())).toEqual([]);
  });

  it("matches the actual target identity and requests the terminal arrivals board", async () => {
    const { overlay, requests } = harness([targetCall()]);

    expect(await overlay.platformUpdates(snapshot())).toEqual([expect.objectContaining({
      expectedPlatform: "2",
      expectedArrival: undefined,
      expectedDeparture: undefined,
      cancelled: false,
      source: "Entur",
    })]);
    const body = await requests[1]!.json() as { query: string; variables: Record<string, string> };
    expect(body.variables).toEqual({
      id: "NSR:StopPlace:60944",
      startTime: "2026-11-13T07:32:00.000Z",
      arrivalDeparture: "arrivals",
    });
    expect(body.query).toContain("serviceJourney { id }");
    expect(body.query).toContain("date");
    expect(body.query).toContain("arrivalDeparture: $arrivalDeparture");
  });

  it("emits only an arrival for an arrival-only stop and compares its arrival event", async () => {
    const call = {
      ...targetCall(),
      aimedDepartureTime: "2026-11-13T09:25:00+01:00",
      expectedArrivalTime: "2026-11-13T09:22:00+01:00",
      expectedDepartureTime: "2026-11-13T09:30:00+01:00",
      realtime: true,
      cancellation: true,
    };
    const values = await harness([call]).overlay.platformUpdates(snapshot());

    expect(values).toHaveLength(1);
    expect(values[0]).toMatchObject({
      expectedArrival: call.expectedArrivalTime,
      expectedDeparture: undefined,
      cancelled: true,
    });
  });

  it("emits only a departure for a departure-only stop and compares its departure event", async () => {
    const call = {
      ...targetCall(),
      aimedArrivalTime: "2026-11-13T09:00:00+01:00",
      aimedDepartureTime: "2026-11-13T09:06:00+01:00",
      expectedArrivalTime: "2026-11-13T09:04:00+01:00",
      expectedDepartureTime: "2026-11-13T09:10:00+01:00",
      realtime: true,
    };
    const { overlay, requests } = harness([call]);
    const values = await overlay.platformUpdates(snapshot({
      stationName: "Oslo S",
      scheduledArrival: null,
      scheduledDeparture: "2026-11-13T08:06:00Z",
    }));

    expect(values).toHaveLength(1);
    expect(values[0]).toMatchObject({ expectedArrival: undefined, expectedDeparture: call.expectedDepartureTime });
    expect((await requests[1]!.json() as { variables: { arrivalDeparture: string } }).variables.arrivalDeparture).toBe("departures");
  });

  it("preserves distinct arrival and departure estimates at an intermediate stop", async () => {
    const call = {
      ...targetCall(),
      aimedDepartureTime: "2026-11-13T09:19:00+01:00",
      expectedArrivalTime: "2026-11-13T09:22:00+01:00",
      expectedDepartureTime: "2026-11-13T09:24:00+01:00",
      realtime: true,
    };
    const values = await harness([call]).overlay.platformUpdates(snapshot({
      scheduledDeparture: "2026-11-13T08:19:00Z",
    }));

    expect(values[0]).toMatchObject({ expectedArrival: call.expectedArrivalTime, expectedDeparture: call.expectedDepartureTime });
  });

  it("rejects another journey even when line, destination, and aimed event agree", async () => {
    const call = { ...targetCall(), serviceJourney: { id: oppositeJourneyId }, cancellation: true };
    expect(await harness([call]).overlay.platformUpdates(snapshot())).toEqual([]);
  });

  it("selects the one exact identity among nearby same-line services", async () => {
    const wrong = { ...targetCall(), serviceJourney: { id: oppositeJourneyId }, cancellation: true };
    const values = await harness([wrong, targetCall()]).overlay.platformUpdates(snapshot());
    expect(values).toHaveLength(1);
    expect(values[0]?.cancelled).toBe(false);
  });

  it.each([undefined, null, {}])("rejects missing official service identity (%s)", async (serviceJourney) => {
    const call = { ...targetCall(), serviceJourney };
    expect(await harness([call]).overlay.platformUpdates(snapshot())).toEqual([]);
  });

  it.each(["2026-11-12", "2026-11-14", undefined])("rejects a different or absent service day (%s)", async (date) => {
    expect(await harness([{ ...targetCall(), date }]).overlay.platformUpdates(snapshot())).toEqual([]);
  });

  it("selects the correct operating day when the journey identity repeats", async () => {
    const previous = {
      ...targetCall(),
      date: "2026-11-12",
      aimedArrivalTime: "2026-11-12T09:17:00+01:00",
      cancellation: true,
    };
    const values = await harness([previous, targetCall()]).overlay.platformUpdates(snapshot());
    expect(values).toHaveLength(1);
    expect(values[0]?.cancelled).toBe(false);
  });

  it("matches an after-midnight call using its service day, not its calendar arrival date", async () => {
    const time = "2026-11-14T00:17:00+01:00";
    const call = { ...targetCall(), aimedArrivalTime: time, expectedArrivalTime: time, realtime: true };
    const values = await harness([call]).overlay.platformUpdates(snapshot({ scheduledArrival: "2026-11-13T23:17:00Z" }));
    expect(values[0]?.expectedArrival).toBe(time);
  });

  it("rejects conflicting exact matches instead of choosing the first", async () => {
    const calls = [targetCall(), { ...targetCall(), cancellation: true, quay: { id: "NSR:Quay:202", publicCode: "3" } }];
    expect(await harness(calls).overlay.platformUpdates(snapshot())).toEqual([]);
    expect(await harness(calls.toReversed()).overlay.platformUpdates(snapshot())).toEqual([]);
  });

  it.each(["2026-11-13T09:16:00+01:00", "2026-11-13T09:17:01+01:00", "invalid"])(
    "rejects another or invalid aimed arrival event (%s)", async (aimedArrivalTime) => {
      expect(await harness([{ ...targetCall(), aimedArrivalTime }]).overlay.platformUpdates(snapshot())).toEqual([]);
    },
  );

  it("requires both corresponding aimed events when both are scheduled", async () => {
    const value = snapshot({ scheduledDeparture: "2026-11-13T08:19:00Z" });
    expect(await harness([targetCall()]).overlay.platformUpdates(value)).toEqual([]);
  });

  it.each(["no-test-r23", "other-feed_VYG:ServiceJourney:1517_443161-R", "20261112_09:06_no-Entur_VYG:ServiceJourney:1517_443161-R"])(
    "does not request enrichment without a consistent Entur identity (%s)", async (nativeId) => {
      const { overlay, requests } = harness([targetCall()]);
      expect(await overlay.platformUpdates({ ...snapshot(), nativeId })).toEqual([]);
      expect(requests).toHaveLength(0);
    },
  );

  it.each([journeyId, `no-Entur_${journeyId}`])("accepts an exact unwrapped identity (%s)", async (nativeId) => {
    expect(await harness([targetCall()]).overlay.platformUpdates({ ...snapshot(), nativeId })).toHaveLength(1);
  });

  it.each([null, "invalid"])("does not request an unidentifiable scheduled event (%s)", async (scheduledArrival) => {
    const { overlay, requests } = harness([targetCall()]);
    expect(await overlay.platformUpdates(snapshot({ scheduledArrival }))).toEqual([]);
    expect(requests).toHaveLength(0);
  });

  it.each(["", "2026-02-30", "2026-11-12"])("rejects an invalid or inconsistent snapshot service day (%s)", async (serviceDate) => {
    const { overlay, requests } = harness([targetCall()]);
    expect(await overlay.platformUpdates({ ...snapshot(), serviceDate })).toEqual([]);
    expect(requests).toHaveLength(0);
  });
});
