import gtfsRealtime, { type transit_realtime } from "gtfs-realtime-bindings";
import { describe, expect, it } from "vitest";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { EnturPlatformOverlay } from "../src/providers/entur.js";
import { enturTripAlertIds } from "../src/providers/entur-trip-alerts.js";

const now = Date.parse("2026-11-13T22:00:00Z"), journey = "VYG:ServiceJourney:1674_481183-R";
function snapshot(): TripSnapshot {
  return { id: "no:test", nativeId: `20261113_23:00_no-Entur_${journey}`, serviceDate: "2026-11-13", source: "transitous",
    operatorName: "Vy", product: "R12", headsign: "Drammen", fetchedAt: new Date(now).toISOString(), alertIds: [],
    stops: [{ stationId: "eu:transitous:no-Entur_NSR:Quay:201", stationName: "Test station", countryCode: "NO", latitude: 60, longitude: 10, sequence: 1,
      scheduledArrival: "2026-11-13T21:50:00Z", scheduledDeparture: "2026-11-13T22:10:00Z", expectedArrival: null, expectedDeparture: null,
      plannedPlatform: null, expectedPlatform: null, platformSource: null, platformObservedAt: null, cancelled: false, passed: false }] };
}
function feed(change?: (entity: transit_realtime.IFeedEntity) => void): transit_realtime.IFeedMessage {
  const entity: transit_realtime.IFeedEntity = { id: "NSB:SituationNumber:example", alert: {
    activePeriod: [{ start: now / 1_000 - 3600, end: now / 1_000 + 3600 }],
    informedEntity: [{ trip: { tripId: journey, startDate: "20261113" } }], headerText: { translation: [{ text: "Train cancelled" }] },
  } };
  change?.(entity);
  return { header: { gtfsRealtimeVersion: "1.0", timestamp: now / 1_000 }, entity: [entity] };
}

describe("Entur exact dated passenger alert matching", () => {
  it("preserves the official passenger alert ID for the same service and active journey window", () => {
    expect(enturTripAlertIds(feed(), snapshot(), now)).toEqual(["entur:NSB:SituationNumber:example"]);
  });

  it.each(["wrong trip", "wrong date", "undated trip", "broad line", "extra route constraint", "wrong quay", "unresolved parent", "deleted", "textless", "expired", "future", "missing periods"])(
    "rejects %s", kind => {
      const value = feed(entity => {
        const alert = entity.alert!, selector = alert.informedEntity![0]!;
        if (kind === "wrong trip") selector.trip!.tripId = "VYG:ServiceJourney:other";
        if (kind === "wrong date") selector.trip!.startDate = "20261112";
        if (kind === "undated trip") delete selector.trip!.startDate;
        if (kind === "broad line") { delete selector.trip; selector.routeId = "VYG:Line:R12"; }
        if (kind === "extra route constraint") selector.routeId = "unknown-route";
        if (kind === "wrong quay") selector.stopId = "NSR:Quay:999";
        if (kind === "unresolved parent") selector.stopId = "NSR:StopPlace:201";
        if (kind === "deleted") entity.isDeleted = true;
        if (kind === "textless") delete alert.headerText;
        if (kind === "expired") alert.activePeriod = [{ start: now / 1_000 - 3600, end: now / 1_000 }];
        if (kind === "future") alert.activePeriod = [{ start: now / 1_000 + 1, end: now / 1_000 + 3600 }];
        if (kind === "missing periods") delete alert.activePeriod;
      });
      expect(enturTripAlertIds(value, snapshot(), now)).toEqual([]);
    },
  );

  it("respects an exact matching quay selector", () => {
    expect(enturTripAlertIds(feed(e => { e.alert!.informedEntity![0]!.stopId = "NSR:Quay:201"; }), snapshot(), now)).toHaveLength(1);
  });

  it("does not join a current alert if this journey's call window is already over", () => {
    const value = snapshot(); value.stops[0]!.scheduledArrival = "2026-11-13T18:00:00Z"; value.stops[0]!.scheduledDeparture = "2026-11-13T18:01:00Z";
    expect(enturTripAlertIds(feed(), value, now)).toEqual([]);
  });

  it.each([undefined, now / 1_000 - 301, now / 1_000 + 121])("rejects missing/stale/future feed time %s", timestamp => {
    const value = feed();
    if (timestamp === undefined) delete value.header.timestamp; else value.header.timestamp = timestamp;
    expect(enturTripAlertIds(value, snapshot(), now)).toEqual([]);
  });

  it("keeps trip/date/stop constraints together within one selector", () => {
    const value = feed(e => { e.alert!.informedEntity = [{ trip: { tripId: journey, startDate: "20261112" } },
      { trip: { tripId: "VYG:ServiceJourney:other", startDate: "20261113" }, stopId: "NSR:Quay:201" }]; });
    expect(enturTripAlertIds(value, snapshot(), now)).toEqual([]);
  });

  it("uses the existing Entur adapter and coalesces simultaneous alert loads", async () => {
    let requests = 0;
    const bytes = gtfsRealtime.transit_realtime.FeedMessage.encode(feed()).finish();
    const overlay = new EnturPlatformOverlay(undefined, undefined, async () => {
      requests += 1; return new Response(new Uint8Array(bytes).buffer);
    }, () => new Date(now), "https://example.test/entur-alerts");
    const result = await Promise.all([overlay.tripAlertIds(snapshot()), overlay.tripAlertIds(snapshot())]);
    expect(result).toEqual([["entur:NSB:SituationNumber:example"], ["entur:NSB:SituationNumber:example"]]);
    expect(requests).toBe(1);
  });

  it("does not fetch alerts for an inconsistent or unrelated journey identity", async () => {
    let requests = 0;
    const overlay = new EnturPlatformOverlay(undefined, undefined, async () => { requests += 1; return new Response(null, { status: 500 }); });
    expect(await overlay.tripAlertIds({ ...snapshot(), nativeId: "unrelated" })).toEqual([]);
    expect(requests).toBe(0);
  });
});
