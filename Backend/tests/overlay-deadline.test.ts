import { describe, expect, it } from "vitest";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { TripSnapshotEnricher, type PlatformRealtimeOverlay } from "../src/providers/platform-overlay.js";
import { SncfRealtimeOverlay } from "../src/providers/sncf-realtime.js";

function snapshot(): TripSnapshot {
  return {
    id: "eu:transitous:20260721_12:00_fr-horaires-sncf_OCESN9836F",
    source: "transitous",
    nativeId: "20260721_12:00_fr-horaires-sncf_OCESN9836F",
    serviceDate: "2026-07-21",
    operatorName: "SNCF",
    product: "TGV 9836",
    headsign: "Montpellier",
    fetchedAt: "2026-07-21T10:00:00.000Z",
    alertIds: [],
    stops: [{
      stationId: "eu:transitous:fr-horaires-sncf_StopPoint:OCETGV-87686006",
      stationName: "Paris Gare de Lyon",
      countryCode: "FR",
      latitude: 48.844,
      longitude: 2.374,
      sequence: 1,
      scheduledArrival: null,
      scheduledDeparture: "2026-07-21T12:00:00.000Z",
      expectedArrival: null,
      expectedDeparture: "2026-07-21T12:00:00.000Z",
      plannedPlatform: null,
      expectedPlatform: null,
      platformSource: null,
      platformObservedAt: null,
      cancelled: false,
      passed: false,
    }, {
      stationId: "eu:transitous:fr-horaires-sncf_StopPoint:OCETGV-87751008",
      stationName: "Marseille Saint-Charles",
      countryCode: "FR",
      latitude: 43.303,
      longitude: 5.38,
      sequence: 2,
      scheduledArrival: "2026-07-21T15:00:00.000Z",
      scheduledDeparture: null,
      expectedArrival: "2026-07-21T15:00:00.000Z",
      expectedDeparture: null,
      plannedPlatform: null,
      expectedPlatform: null,
      platformSource: null,
      platformObservedAt: null,
      cancelled: false,
      passed: false,
    }],
  };
}

describe("overlay deadline", () => {
  it("skips an overlay that misses its deadline without losing the others", async () => {
    const hanging: PlatformRealtimeOverlay = {
      sourceName: "Slow feed",
      supportedCountryCodes: new Set(["FR"]),
      platformUpdates: () => new Promise(() => {}),
      tripAlertIds: () => new Promise(() => {}),
    };
    const fast: PlatformRealtimeOverlay = {
      sourceName: "Fast feed",
      supportedCountryCodes: new Set(["FR"]),
      platformUpdates: async () => [{
        stopSequence: 1,
        stationId: null,
        expectedPlatform: "13",
        observedAt: "2026-07-21T10:00:00.000Z",
        source: "Fast feed",
      }],
    };

    const started = Date.now();
    const value = await new TripSnapshotEnricher([hanging, fast], [], 50).enrich(snapshot());

    expect(Date.now() - started).toBeLessThan(1_000);
    expect(value.stops[0]).toMatchObject({ expectedPlatform: "13", platformSource: "Fast feed" });
  });
});

describe("SNCF SIRI-ET", () => {
  function siri(calls: string): string {
    return `<Siri><ServiceDelivery><EstimatedTimetableDelivery><EstimatedJourneyVersionFrame>
      <EstimatedVehicleJourney>
        <RecordedAtTime>2026-07-21T12:00:30Z</RecordedAtTime>
        <FramedVehicleJourneyRef><DataFrameRef>2026-07-21</DataFrameRef></FramedVehicleJourneyRef>
        <OriginAimedDepartureTime>2026-07-21T14:00:00+02:00</OriginAimedDepartureTime>
        <TrainNumbers><TrainNumberRef>9836</TrainNumberRef></TrainNumbers>
        <EstimatedCalls>${calls}</EstimatedCalls>
      </EstimatedVehicleJourney>
    </EstimatedJourneyVersionFrame></EstimatedTimetableDelivery></ServiceDelivery></Siri>`;
  }

  function overlay(fetcher: typeof fetch, now: () => Date = () => new Date("2026-07-21T12:00:00.000Z")) {
    return new SncfRealtimeOverlay(
      "https://example.test/trips.pb",
      async (input, init) => String(input).includes("siri")
        ? fetcher(input, init)
        : new Response("unavailable", { status: 503 }),
      now,
      null,
      "https://example.test/siri.xml",
    );
  }

  it("does not move a platform onto a neighbouring stop by Order", async () => {
    // Avignon TGV (87318964) is not in this trip; Order 2 must not land on stop 1 or 2.
    const feed = siri(`<EstimatedCall>
      <StopPointRef>FR:ScheduledStopPoint::87318964</StopPointRef><Order>2</Order>
      <DeparturePlatformName>B</DeparturePlatformName>
    </EstimatedCall>`);
    const updates = await overlay(async () => new Response(feed)).platformUpdates(snapshot());

    expect(updates).toEqual([]);
  });

  it("does not treat an Order-only call as a station identity", async () => {
    const feed = siri(`<EstimatedCall>
      <StopPointRef>FR:ScheduledStopPoint::unknown</StopPointRef><Order>1</Order>
      <DeparturePlatformName>13</DeparturePlatformName>
    </EstimatedCall><EstimatedCall>
      <StopPointRef>FR:ScheduledStopPoint::unknown</StopPointRef><Order>2</Order>
      <ArrivalPlatformName>C</ArrivalPlatformName>
    </EstimatedCall>`);
    const updates = await overlay(async () => new Response(feed)).platformUpdates(snapshot());

    expect(updates).toEqual([]);
  });

  it("briefly stops retrying the SIRI feed after a failure", async () => {
    let now = new Date("2026-07-21T12:00:00.000Z");
    let requests = 0;
    const sncf = overlay(async () => {
      requests += 1;
      return new Response("timeout", { status: 504 });
    }, () => now);

    await sncf.platformUpdates(snapshot());
    await sncf.platformUpdates(snapshot());
    expect(requests).toBe(1);

    now = new Date("2026-07-21T12:01:30.000Z");
    await sncf.platformUpdates(snapshot());
    expect(requests).toBe(2);
  });
});
