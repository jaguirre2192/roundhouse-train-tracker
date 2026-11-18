import { describe, expect, it } from "vitest";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { DigitrafficPlatformOverlay } from "../src/providers/digitraffic.js";
import { digitrafficPassengerAlertIds, type DigitrafficPassengerMessage } from "../src/providers/digitraffic-passenger-alerts.js";
import { TripSnapshotEnricher } from "../src/providers/platform-overlay.js";

const now = Date.parse("2026-11-13T17:40:00Z");
const train = { trainNumber: 10, departureDate: "2026-11-13", timeTableRows: [] };
const calls = [{ stationShortCode: "TKL", from: now, to: now + 120_000 }];
function message(): DigitrafficPassengerMessage {
  return { id: "MVM202611131234", version: 2, trainNumber: 10, trainDepartureDate: "2026-11-13", stations: ["TKL"],
    startValidity: "2026-11-13T17:00:00Z", endValidity: "2026-11-13T19:00:00Z", video: { text: { en: "Train delayed due to signalling fault." } } };
}
function snapshot(): TripSnapshot {
  return { id: "fi:10", nativeId: "20261113_19:31_fi-digitraffic_10_20261113", serviceDate: "2026-11-13", source: "transitous",
    operatorName: "VR", product: "IC 10", headsign: "Helsinki", fetchedAt: new Date(now).toISOString(), alertIds: ["base-alert"],
    stops: [{ stationId: "fi-TKL", stationName: "Tikkurila", countryCode: "FI", latitude: 60.292, longitude: 25.044, sequence: 1,
      scheduledArrival: "2026-11-13T17:30:00Z", scheduledDeparture: "2026-11-13T17:31:00Z", expectedArrival: null, expectedDeparture: null,
      plannedPlatform: null, expectedPlatform: null, platformSource: null, platformObservedAt: null, cancelled: false, passed: false }] };
}

describe("Digitraffic passenger alerts", () => {
  it("preserves a public exact train/date/station notice and version without copying its text into evidence", () => {
    expect(digitrafficPassengerAlertIds(train, calls, [message(), message()], now)).toEqual(["digitraffic:passenger:MVM202611131234:v2"]);
  });

  it.each([
    ["other train", { trainNumber: 11 }], ["other service date", { trainDepartureDate: "2026-11-12" }],
    ["undated train", { trainDepartureDate: undefined }], ["general station notice", { trainNumber: undefined }],
    ["another station", { stations: ["HKI"] }], ["malformed stations", { stations: "TKL" }],
    ["not yet valid", { startValidity: "2026-11-13T18:00:00Z" }], ["expired", { endValidity: "2026-11-13T17:40:00Z" }],
    ["missing validity", { endValidity: undefined }], ["invalid validity", { startValidity: "invalid" }],
    ["invalid version", { version: -1 }], ["no passenger text", { video: { text: {} } }],
  ] as const)("rejects %s", (_name, change) => {
    expect(digitrafficPassengerAlertIds(train, calls, [{ ...message(), ...change }], now)).toEqual([]);
  });

  it("does not apply a current notice to a station call outside its validity window", () => {
    expect(digitrafficPassengerAlertIds(train, [{ ...calls[0]!, from: now + 7_200_000, to: now + 7_200_000 }], [message()], now)).toEqual([]);
  });

  it("accepts train-wide notices only for a bounded matching journey window", () => {
    expect(digitrafficPassengerAlertIds(train, calls, [{ ...message(), stations: [] }], now)).toHaveLength(1);
    expect(digitrafficPassengerAlertIds(train, [], [{ ...message(), stations: [] }], now)).toEqual([]);
  });

  it("shares exact train resolution with timings and preserves base plus passenger IDs", async () => {
    const requests: URL[] = [], value = snapshot();
    const overlay = new DigitrafficPlatformOverlay("https://example.test", async input => {
      const url = new URL(String(input)); requests.push(url);
      if (url.pathname.includes("metadata")) return Response.json([{ passengerTraffic: true, stationName: "Tikkurila", stationShortCode: "TKL" }]);
      if (url.pathname.includes("passenger-information")) return Response.json([message()]);
      return Response.json([{ ...train, timeTableRows: [{ stationShortCode: "TKL", type: "DEPARTURE", scheduledTime: "2026-11-13T17:31:00Z",
        liveEstimateTime: "2026-11-13T17:42:00Z", cancelled: false }] }]);
    }, () => new Date(now));
    const enriched = await new TripSnapshotEnricher([overlay]).enrich(value);
    expect(enriched.alertIds).toEqual(["base-alert", "digitraffic:passenger:MVM202611131234:v2"]);
    expect(enriched.stops[0]?.expectedDeparture).toBe("2026-11-13T17:42:00.000Z");
    expect(requests.filter(url => url.pathname.includes("live-trains"))).toHaveLength(1);
    expect(requests.find(url => url.pathname.includes("passenger-information"))?.searchParams.get("train_number")).toBe("10");
    expect(requests.find(url => url.pathname.includes("passenger-information"))?.searchParams.get("train_departure_date")).toBe("2026-11-13");
    await overlay.tripAlertIds(value);
    expect(requests.filter(url => url.pathname.includes("passenger-information"))).toHaveLength(1);
  });

  it("does not query passenger messages without an unambiguous matched train", async () => {
    const paths: string[] = [];
    const overlay = new DigitrafficPlatformOverlay("https://example.test", async input => {
      const path = new URL(String(input)).pathname; paths.push(path);
      return Response.json(path.includes("metadata") ? [{ passengerTraffic: true, stationName: "Tikkurila", stationShortCode: "TKL" }] : []);
    });
    expect(await overlay.tripAlertIds(snapshot())).toEqual([]);
    expect(paths.some(path => path.includes("passenger-information"))).toBe(false);
  });
});
