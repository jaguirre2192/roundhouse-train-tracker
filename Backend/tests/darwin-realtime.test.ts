import { describe, expect, it, vi } from "vitest";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import {
  DarwinRealtimeOverlay,
  parseDarwinDocument,
  type DarwinTripFeed,
} from "../src/providers/darwin-realtime.js";
import { TripSnapshotEnricher } from "../src/providers/platform-overlay.js";

const uid = "G15439";
const serviceDate = "2026-07-21";

const snapshot: TripSnapshot = {
  id: "eu:transitous:20260721_21:45_gb-great-britain_G15439_20260721",
  source: "transitous",
  nativeId: "20260721_21:45_gb-great-britain_G15439_20260721",
  serviceDate,
  operatorName: "GWR",
  product: "GWR",
  headsign: "Bristol Temple Meads",
  fetchedAt: "2026-07-21T20:40:00.000Z",
  alertIds: [],
  stops: [{
    stationId: "eu:transitous:gb-great-britain_9100PADTON8",
    stationName: "London Paddington",
    countryCode: "GB",
    latitude: 51.516,
    longitude: -0.176,
    sequence: 1,
    scheduledArrival: null,
    scheduledDeparture: "2026-07-21T21:00:00.000Z",
    expectedArrival: null,
    expectedDeparture: "2026-07-21T21:00:00.000Z",
    plannedPlatform: "8",
    expectedPlatform: "8",
    platformSource: "Transitous",
    platformObservedAt: null,
    cancelled: false,
    passed: false,
  }, {
    stationId: "eu:transitous:gb-great-britain_9100RDNGSTN12",
    stationName: "Reading",
    countryCode: "GB",
    latitude: 51.459,
    longitude: -0.972,
    sequence: 2,
    scheduledArrival: "2026-07-21T21:27:00.000Z",
    scheduledDeparture: "2026-07-21T21:29:00.000Z",
    expectedArrival: "2026-07-21T21:27:00.000Z",
    expectedDeparture: "2026-07-21T21:29:00.000Z",
    plannedPlatform: "12",
    expectedPlatform: "12",
    platformSource: "Transitous",
    platformObservedAt: null,
    cancelled: false,
    passed: false,
  }],
};

const baseXML = `<?xml version="1.0"?>
<Pport ts="2026-07-21T21:42:30.1234567+01:00">
  <uR>
    <schedule rid="202607217154439" uid="${uid}" ssd="${serviceDate}">
      <ns2:OR wtd="22:00" ptd="22:00" tpl="PADTON" />
      <ns2:IP wta="22:27" wtd="22:29" pta="22:27" ptd="22:29" tpl="RDNGSTN" can="true" />
      <ns2:cancelReason>576</ns2:cancelReason>
    </schedule>
    <TS rid="202607217154439" uid="${uid}" ssd="${serviceDate}">
      <ns5:Location tpl="PADTON" wtd="22:00" ptd="22:00">
        <ns5:dep et="22:05" src="Darwin" />
        <ns5:plat platsrc="M" conf="true">9</ns5:plat>
        <ns5:LateReason>734</ns5:LateReason>
      </ns5:Location>
      <ns5:Location tpl="RDNGSTN" wta="22:27" wtd="22:29" pta="22:27" ptd="22:29">
        <ns5:arr et="22:28" src="Darwin" />
        <ns5:dep et="22:30" src="Darwin" />
        <ns5:plat>12B</ns5:plat>
      </ns5:Location>
    </TS>
    <trainAlert>
      <ns8:AlertID>4079</ns8:AlertID>
      <ns8:AlertServices>
        <ns8:AlertService RID="202607217154439" UID="${uid}" SSD="${serviceDate}" />
      </ns8:AlertServices>
    </trainAlert>
  </uR>
</Pport>`;

function feed(xml = baseXML): DarwinTripFeed {
  const state = parseDarwinDocument(xml, uid, serviceDate);
  return { latestTrip: vi.fn().mockResolvedValue(state) };
}

describe("National Rail Darwin overlay", () => {
  it("maps official platform changes, forecasts, partial cancellations, and alerts", async () => {
    const overlay = new DarwinRealtimeOverlay(feed());
    const enriched = await new TripSnapshotEnricher([overlay]).enrich(snapshot);

    expect(enriched.stops[0]).toMatchObject({
      expectedDeparture: "2026-07-21T21:05:00.000Z",
      plannedPlatform: "8",
      expectedPlatform: "9",
      platformSource: "National Rail Darwin",
      platformObservedAt: "2026-07-21T20:42:30.123Z",
      cancelled: false,
    });
    expect(enriched.stops[1]).toMatchObject({
      expectedArrival: "2026-07-21T21:28:00.000Z",
      expectedDeparture: "2026-07-21T21:30:00.000Z",
      expectedPlatform: "12B",
      cancelled: true,
    });
    expect(enriched.alertIds).toEqual(expect.arrayContaining([
      "darwin-cancellation-576",
      "darwin-late-734",
      "darwin-train-alert-4079",
    ]));
  });

  it("merges forecast-only patches without discarding the latest platform", () => {
    const initial = parseDarwinDocument(baseXML, uid, serviceDate);
    const patch = `
      <Pport ts="2026-07-21T21:47:30.0000000+01:00">
        <uR><TS rid="202607217154439" uid="${uid}" ssd="${serviceDate}">
          <ns5:Location tpl="PADTON"><ns5:dep et="22:07" src="Darwin" /></ns5:Location>
        </TS></uR>
      </Pport>`;
    const updated = parseDarwinDocument(patch, uid, serviceDate, initial);

    expect(updated?.locations.get("PADTON")).toMatchObject({
      expectedDeparture: "22:07",
      platform: "9",
      platformSuppressed: false,
    });
    expect(updated?.observedAt).toBe("2026-07-21T20:47:30.000Z");
  });

  it("clears a platform when Darwin marks it as suppressed", async () => {
    const initial = parseDarwinDocument(baseXML, uid, serviceDate);
    const suppression = `
      <Pport ts="2026-07-21T21:48:00.0000000+01:00">
        <uR><TS rid="202607217154439" uid="${uid}" ssd="${serviceDate}">
          <ns5:Location tpl="PADTON">
            <ns5:plat platsup="true" cisPlatsup="true">9</ns5:plat>
          </ns5:Location>
        </TS></uR>
      </Pport>`;
    const state = parseDarwinDocument(suppression, uid, serviceDate, initial);
    const overlay = new DarwinRealtimeOverlay({ latestTrip: vi.fn().mockResolvedValue(state) });
    const enriched = await new TripSnapshotEnricher([overlay]).enrich(snapshot);

    // Suppression is a realtime observation that hides both the live and timetable platform.
    expect(enriched.stops[0]).toMatchObject({
      plannedPlatform: null,
      expectedPlatform: null,
      platformSource: "National Rail Darwin",
      platformObservedAt: "2026-07-21T20:48:00.000Z",
    });
  });

  it("replaces the full cancellation state when a later schedule restores a stop", async () => {
    const initial = parseDarwinDocument(baseXML, uid, serviceDate);
    const restored = parseDarwinDocument(`
      <Pport ts="2026-07-21T21:50:00.0000000+01:00"><uR>
        <schedule rid="202607217154439" uid="${uid}" ssd="${serviceDate}">
          <ns2:OR tpl="PADTON" /><ns2:IP tpl="RDNGSTN" />
        </schedule>
      </uR></Pport>`, uid, serviceDate, initial);

    expect(restored?.locations.get("RDNGSTN")?.cancelled).toBe(false);
    expect([...restored?.alertIds ?? []]).not.toContain("darwin-cancellation-576");
  });

  it("ignores non-Transitous UK trip identifiers without calling the feed", async () => {
    const source = feed();
    const overlay = new DarwinRealtimeOverlay(source);
    await expect(overlay.platformUpdates({ ...snapshot, nativeId: "unrelated-trip" })).resolves.toEqual([]);
    expect(source.latestTrip).not.toHaveBeenCalled();
  });
});
