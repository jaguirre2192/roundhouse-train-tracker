import { transit_realtime } from "gtfs-realtime-bindings";
import { describe, expect, it, vi } from "vitest";
import { diffSnapshots } from "../src/domain/events.js";
import { defaultPushPreferences } from "../src/domain/snapshot.js";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { TripSnapshotEnricher } from "../src/providers/platform-overlay.js";
import { SncfRealtimeOverlay } from "../src/providers/sncf-realtime.js";

const tripId = "OCESN9836F1187_F:OUI:FR:Line::fixture";

function snapshot(): TripSnapshot {
  return {
    id: `eu:transitous:20260721_12:00_fr-horaires-sncf_${tripId}`,
    source: "transitous",
    nativeId: `20260721_12:00_fr-horaires-sncf_${tripId}`,
    serviceDate: "2026-07-21",
    operatorName: "SNCF",
    product: "TGV 9836",
    headsign: "Montpellier",
    fetchedAt: "2026-07-21T10:00:00.000Z",
    alertIds: [],
    stops: [{
      stationId: "eu:transitous:fr-horaires-sncf_StopPoint:OCETGV-87756056",
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
    }],
  };
}

function feed(scheduleRelationship = transit_realtime.TripDescriptor.ScheduleRelationship.SCHEDULED): Uint8Array {
  return transit_realtime.FeedMessage.encode({
    header: { gtfsRealtimeVersion: "2.0", timestamp: 1_784_635_200 },
    entity: [{
      id: "fixture",
      tripUpdate: {
        trip: { tripId, startDate: "20260721", scheduleRelationship },
        stopTimeUpdate: [{
          stopSequence: 1,
          stopId: "StopPoint:OCETGV-87756056",
          departure: { delay: 420, time: 1_784_635_620 },
        }],
      },
    }],
  }).finish();
}

function alertFeed(): Uint8Array {
  return transit_realtime.FeedMessage.encode({
    header: { gtfsRealtimeVersion: "2.0", timestamp: 1_784_635_200 },
    entity: [{
      id: "QOM:fixture:9836",
      alert: {
        activePeriod: [{ start: 1_784_630_000, end: 1_784_640_000 }],
        informedEntity: [{ trip: { tripId: "OCESN9836F" } }],
        effect: transit_realtime.Alert.Effect.SIGNIFICANT_DELAYS,
      },
    }],
  }).finish();
}

function siriFeed(): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
    <Siri><ServiceDelivery><EstimatedTimetableDelivery><EstimatedJourneyVersionFrame>
      <EstimatedVehicleJourney>
        <RecordedAtTime>2026-07-21T12:00:30Z</RecordedAtTime>
        <FramedVehicleJourneyRef><DataFrameRef>2026-07-21</DataFrameRef></FramedVehicleJourneyRef>
        <OriginAimedDepartureTime>2026-07-21T14:00:00+02:00</OriginAimedDepartureTime>
        <TrainNumbers><TrainNumberRef>9836</TrainNumberRef></TrainNumbers>
        <EstimatedCalls><EstimatedCall>
          <StopPointRef>FR:ScheduledStopPoint::87756056</StopPointRef><Order>1</Order>
          <ExpectedDepartureTime>2026-07-21T14:07:00+02:00</ExpectedDepartureTime>
          <DeparturePlatformName>13</DeparturePlatformName>
        </EstimatedCall></EstimatedCalls>
      </EstimatedVehicleJourney>
    </EstimatedJourneyVersionFrame></EstimatedTimetableDelivery></ServiceDelivery></Siri>`;
}

function protobufResponse(bytes: Uint8Array): Response {
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  return new Response(copy.buffer, { status: 200 });
}

describe("SncfRealtimeOverlay", () => {
  it("joins official SNCF trip updates and preserves expected departure", async () => {
    const overlay = new SncfRealtimeOverlay(
      "https://example.test/sncf.pb",
      async () => protobufResponse(feed()),
      () => new Date("2026-07-21T12:00:00.000Z"),
    );

    const value = await new TripSnapshotEnricher([overlay.timingOverlay, overlay]).enrich(snapshot());

    expect(value.stops[0]).toMatchObject({
      expectedDeparture: "2026-07-21T12:07:00.000Z",
      cancelled: false,
    });
  });

  it("retains fast GTFS timing and cancellation when SIRI never responds", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      const overlay = new SncfRealtimeOverlay(
        "https://example.test/trips.pb",
        async (input) => String(input).includes("siri")
          ? new Promise<Response>(() => {})
          : protobufResponse(feed(transit_realtime.TripDescriptor.ScheduleRelationship.DELETED)),
        () => new Date("2026-07-21T12:00:00.000Z"),
        null,
        "https://example.test/siri.xml",
      );

      const value = await new TripSnapshotEnricher([overlay.timingOverlay, overlay], [], 20).enrich(snapshot());

      expect(value.stops[0]).toMatchObject({
        expectedDeparture: "2026-07-21T12:07:00.000Z",
        cancelled: true,
      });
    } finally {
      error.mockRestore();
    }
  });

  it("retains SIRI platforms when the GTFS feed fails", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      const overlay = new SncfRealtimeOverlay(
        "https://example.test/trips.pb",
        async (input) => String(input).includes("siri")
          ? new Response(siriFeed(), { status: 200 })
          : new Response(null, { status: 503 }),
        () => new Date("2026-07-21T12:00:00.000Z"),
        null,
        "https://example.test/siri.xml",
      );

      const value = await new TripSnapshotEnricher([overlay.timingOverlay, overlay]).enrich(snapshot());

      expect(value.stops[0]).toMatchObject({ expectedPlatform: "13", platformSource: "SNCF SIRI-ET" });
    } finally {
      error.mockRestore();
    }
  });

  it("marks a deleted SNCF trip as cancelled", async () => {
    const overlay = new SncfRealtimeOverlay(
      "https://example.test/sncf.pb",
      async () => protobufResponse(feed(transit_realtime.TripDescriptor.ScheduleRelationship.DELETED)),
    );

    const value = await new TripSnapshotEnricher([overlay.timingOverlay, overlay]).enrich(snapshot());

    expect(value.stops[0]?.cancelled).toBe(true);
  });

  it("joins a federated European trip by train number, service date, and UIC station", async () => {
    const federated = snapshot();
    federated.id = "eu:transitous:20260721_12:00_ch-opentransportdataswiss26_train-9836";
    federated.nativeId = "20260721_12:00_ch-opentransportdataswiss26_train-9836";
    federated.stops[0]!.stationId = "eu:transitous:ch-opentransportdataswiss26_Parent8775605";
    const overlay = new SncfRealtimeOverlay(
      "https://example.test/sncf.pb",
      async () => protobufResponse(feed()),
    );

    const value = await new TripSnapshotEnricher([overlay.timingOverlay, overlay]).enrich(federated);

    expect(value.stops[0]?.expectedDeparture).toBe("2026-07-21T12:07:00.000Z");
  });

  it("joins active official Service Alerts by commercial train number", async () => {
    const overlay = new SncfRealtimeOverlay(
      "https://example.test/trips.pb",
      async (input) => protobufResponse(String(input).includes("alerts") ? alertFeed() : feed()),
      () => new Date("2026-07-21T12:00:00.000Z"),
      "https://example.test/alerts.pb",
    );

    const value = await new TripSnapshotEnricher([overlay.timingOverlay, overlay]).enrich(snapshot());

    expect(value.alertIds).toEqual(["sncf:QOM:fixture:9836"]);
  });

  it("maps SIRI-ET platform assignments into deduplicable watcher events", async () => {
    const previous = snapshot();
    const overlay = new SncfRealtimeOverlay(
      "https://example.test/trips.pb",
      async (input) => {
        const url = String(input);
        if (url.includes("siri")) return new Response(siriFeed(), { status: 200 });
        return protobufResponse(url.includes("alerts") ? alertFeed() : feed());
      },
      () => new Date("2026-07-21T12:00:00.000Z"),
      "https://example.test/alerts.pb",
      "https://example.test/siri.xml",
    );

    const current = await new TripSnapshotEnricher([overlay.timingOverlay, overlay]).enrich(previous);
    const events = diffSnapshots(previous, current, defaultPushPreferences);

    expect(current.stops[0]).toMatchObject({
      expectedDeparture: "2026-07-21T12:07:00.000Z",
      expectedPlatform: "13",
      platformSource: "SNCF SIRI-ET",
    });
    expect(events).toEqual(expect.arrayContaining([
      expect.objectContaining({ kind: "platform-change", oldValue: null, newValue: "13" }),
      expect.objectContaining({ kind: "delay-threshold", newValue: "7" }),
      expect.objectContaining({ kind: "disruption", newValue: "sncf:QOM:fixture:9836" }),
    ]));
  });

  it("coalesces prefetch with active enrichment and reuses the warmed large feed", async () => {
    const requests: string[] = [];
    let resolveSiri: (response: Response) => void = () => {};
    const pending = new Promise<Response>((resolve) => { resolveSiri = resolve; });
    const overlay = new SncfRealtimeOverlay("https://example.test/trips.pb", async (input) => {
      requests.push(String(input));
      return String(input).includes("siri") ? pending : protobufResponse(feed());
    }, () => new Date("2026-07-21T12:00:00Z"), null, "https://example.test/siri.xml");
    const warming = overlay.prefetch(snapshot());
    const current = overlay.platformUpdates(snapshot());
    resolveSiri(new Response(siriFeed()));
    await warming;
    expect(await current).toEqual([expect.objectContaining({ expectedPlatform: "13" })]);
    expect(await overlay.platformUpdates(snapshot())).toHaveLength(1);
    expect(requests.filter((url) => url.includes("siri"))).toHaveLength(1);
  });

  it("learns UUID-to-UIC identities only from an exact SIRI call for subsequent fast GTFS updates", async () => {
    const value = snapshot();
    value.stops[0]!.stationId = "eu:transitous:fr-horaires-sncf_FR::LMO:91653280-cb0a-11e8-8bfa-f784c1c7c611:";
    const siri = siriFeed().replace("<Order>1</Order>", `<Order>1</Order>
      <StopPointName>Paris Gare de Lyon</StopPointName><AimedDepartureTime>2026-07-21T12:00:00Z</AimedDepartureTime>`);
    const overlay = new SncfRealtimeOverlay("https://example.test/trips.pb", async (input) =>
      String(input).includes("siri") ? new Response(siri) : protobufResponse(feed()),
    () => new Date("2026-07-21T12:00:00Z"), null, "https://example.test/siri.xml");
    expect(await overlay.timingOverlay.platformUpdates(value)).toEqual([]);
    await overlay.platformUpdates(value);
    expect(await overlay.timingOverlay.platformUpdates(value)).toEqual([expect.objectContaining({
      stationId: value.stops[0]!.stationId, expectedDeparture: "2026-07-21T12:07:00.000Z", source: "SNCF GTFS-RT",
    })]);
  });

});
