import { describe, expect, it } from "vitest";
import { diffSnapshots } from "../src/domain/events.js";
import { defaultPushPreferences, type TripSnapshot } from "../src/domain/snapshot.js";
import { ElronRealtimeOverlay } from "../src/providers/elron-realtime.js";
import { TripSnapshotEnricher } from "../src/providers/platform-overlay.js";

function trip(): TripSnapshot {
  return {
    id: "eu:transitous:elron-e34",
    source: "transitous",
    nativeId: "elron-e34",
    serviceDate: "2026-07-21",
    operatorName: "ELRON",
    product: "E34",
    headsign: "Tartu",
    fetchedAt: "2026-07-21T18:10:00.000Z",
    alertIds: [],
    stops: [{
      stationId: "eu:transitous:ee-elron_10137",
      stationName: "Tallinn",
      countryCode: "EE",
      latitude: 59.4405,
      longitude: 24.73695,
      sequence: 1,
      scheduledArrival: null,
      scheduledDeparture: "2026-07-21T18:20:00.000Z",
      expectedArrival: null,
      expectedDeparture: "2026-07-21T18:20:00.000Z",
      plannedPlatform: null,
      expectedPlatform: null,
      platformSource: null,
      platformObservedAt: null,
      cancelled: false,
      passed: false,
    }, {
      stationId: "eu:transitous:ee-elron_34046",
      stationName: "Tapa",
      countryCode: "EE",
      latitude: 59.264,
      longitude: 25.962,
      sequence: 2,
      scheduledArrival: "2026-07-21T19:25:00.000Z",
      scheduledDeparture: "2026-07-21T19:27:00.000Z",
      expectedArrival: "2026-07-21T19:25:00.000Z",
      expectedDeparture: "2026-07-21T19:27:00.000Z",
      plannedPlatform: null,
      expectedPlatform: null,
      platformSource: null,
      platformObservedAt: null,
      cancelled: false,
      passed: false,
    }],
  };
}

function fixtureFetcher(
  requests: Request[],
  options: { changed?: boolean; cancelled?: boolean; ambiguous?: boolean } = {},
): typeof fetch {
  return async (input, init) => {
    const request = new Request(input, init);
    requests.push(request);
    const path = new URL(request.url).pathname;
    if (path.endsWith("/stops_data.json")) {
      return Response.json({ data: [{ peatus: "Tallinn", latitude: "59.4405", longitude: "24.73695", teade: "" }] });
    }
    if (path.includes("/live-map/stop/")) {
      const movement = {
        plaaniline_aeg: "21:20",
        tegelik_aeg: "",
        kuupaev: "2026-07-21",
        reis: "106",
        liin: "Tallinn - Tartu",
        sihtjaam: "Tartu",
        erinevus_plaanist: "7",
        lisateade: "",
        pohjus_teade: "taristurikke tõttu",
        peatuskoht: options.changed ? "8" : "5",
        peatuskoht_muutunud: options.changed ? "t" : "f",
        reisi_lopp_peatus: "f",
        reisi_staatus: options.cancelled ? "reis tühistatud" : "hilineb peatuses",
      };
      return Response.json({ data: options.ambiguous ? [movement, { ...movement, reis: "108" }] : [movement] });
    }
    return Response.json({ data: [{
      reis: "106",
      liin: "Tallinn - Tartu",
      reisi_algus_aeg: "21:20",
      reisi_lopp_aeg: "23:55",
      kiirus: "88",
      latitude: "59.100000",
      longitude: "25.100000",
      rongi_suund: "135",
      erinevus_plaanist: "7",
      lisateade: "",
      pohjus_teade: "taristurikke tõttu",
      avalda_kodulehel: "",
      asukoha_uuendus: "2026-07-21 21:10:00",
      reisi_staatus: options.cancelled ? "reis tühistatud" : "hilineb peatuses",
      viimane_peatus: "Tallinn",
    }] });
  };
}

describe("Elron live-map overlay", () => {
  it("still checks the upcoming station when a recent passed anchor is absent from the official feed", async () => {
    const current = trip();
    current.stops.unshift({ ...current.stops[0]!, stationId: "unknown", stationName: "Unknown", latitude: 0, longitude: 0,
      sequence: 0, passed: true, scheduledDeparture: "2026-07-21T18:00:00Z", expectedDeparture: "2026-07-21T18:00:00Z" });
    const overlay = new ElronRealtimeOverlay("https://example.test", fixtureFetcher([]), () => new Date(current.fetchedAt));
    expect(await overlay.platformUpdates(current)).toContainEqual(expect.objectContaining({ stationId: "eu:transitous:ee-elron_10137", expectedPlatform: "5" }));
  });

  it("maps official platform, delay, disruption, and fresh train position", async () => {
    const requests: Request[] = [];
    const overlay = new ElronRealtimeOverlay(
      "https://elron.test",
      fixtureFetcher(requests),
      () => new Date("2026-07-21T18:10:15.000Z"),
    );
    const previous = trip();
    const current = await new TripSnapshotEnricher([overlay], [overlay]).enrich(previous);

    expect(current.stops[0]).toEqual(expect.objectContaining({
      plannedPlatform: "5",
      expectedPlatform: "5",
      expectedDeparture: "2026-07-21T18:27:00.000Z",
      cancelled: false,
      platformSource: "Elron live map",
    }));
    expect(current.alertIds).toHaveLength(1);
    expect(current.alertIds[0]).toMatch(/^elron:/u);
    expect(current.positions).toEqual([expect.objectContaining({
      latitude: 59.1,
      longitude: 25.1,
      heading: 135,
      source: "real",
      asOf: "2026-07-21T18:10:00.000Z",
      provider: "Elron live map",
    })]);
    expect(requests).toHaveLength(3);

    const first = diffSnapshots(previous, current, defaultPushPreferences);
    const second = diffSnapshots(previous, current, defaultPushPreferences);
    expect(first).toEqual(expect.arrayContaining([
      expect.objectContaining({ kind: "platform-change", oldValue: null, newValue: "5" }),
      expect.objectContaining({ kind: "delay-threshold", newValue: "7" }),
      expect.objectContaining({ kind: "disruption", newValue: current.alertIds[0] }),
    ]));
    expect(first.map((event) => event.fingerprint)).toEqual(second.map((event) => event.fingerprint));
  });

  it("preserves the prior planned platform and reports an explicit platform change", async () => {
    const overlay = new ElronRealtimeOverlay(
      "https://elron.test",
      fixtureFetcher([], { changed: true }),
      () => new Date("2026-07-21T18:10:15.000Z"),
    );
    const previous = trip();
    previous.stops[0] = { ...previous.stops[0]!, plannedPlatform: "5", expectedPlatform: "5" };
    const current = await new TripSnapshotEnricher([overlay]).enrich(previous);
    expect(current.stops[0]).toEqual(expect.objectContaining({ plannedPlatform: "5", expectedPlatform: "8" }));
    expect(current.alertIds).toContainEqual(expect.stringMatching(/^elron:platform-change:2026-07-21:106:[0-9a-f]{8}:8$/u));
    expect(diffSnapshots(previous, current, defaultPushPreferences)).toContainEqual(expect.objectContaining({
      kind: "platform-change",
      oldValue: "5",
      newValue: "8",
    }));
  });

  it("maps a published cancellation status", async () => {
    const overlay = new ElronRealtimeOverlay(
      "https://elron.test",
      fixtureFetcher([], { cancelled: true }),
      () => new Date("2026-07-21T18:10:15.000Z"),
    );
    const previous = trip();
    const current = await new TripSnapshotEnricher([overlay]).enrich(previous);
    expect(current.stops[0]?.cancelled).toBe(true);
    expect(diffSnapshots(previous, current, defaultPushPreferences)).toContainEqual(expect.objectContaining({
      kind: "cancellation",
      stopId: "eu:transitous:ee-elron_10137",
    }));
  });

  it("rejects an ambiguous same-time board join", async () => {
    const overlay = new ElronRealtimeOverlay(
      "https://elron.test",
      fixtureFetcher([], { ambiguous: true }),
      () => new Date("2026-07-21T18:10:15.000Z"),
    );
    expect(await overlay.platformUpdates(trip())).toEqual([]);
    expect(await overlay.tripAlertIds(trip())).toEqual([]);
    expect(await overlay.positionUpdates(trip())).toEqual([]);
  });
});
