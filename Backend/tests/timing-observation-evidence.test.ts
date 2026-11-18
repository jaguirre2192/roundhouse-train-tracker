import { afterEach, describe, expect, it, vi } from "vitest";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { TripSnapshotEnricher, type PlatformObservation } from "../src/providers/platform-overlay.js";

const at = "2026-11-16T18:36:00.000Z";
const snapshot = (): TripSnapshot => ({ id: "eu:transitous:dk-test", source: "transitous", nativeId: "dk-test",
  serviceDate: "2026-11-16", operatorName: "DSB", product: "IC 2360", headsign: "København H", fetchedAt: at, alertIds: [],
  stops: [{ stationId: "eu:transitous:dk-rejseplanen_8600223", stationName: "Odense", countryCode: "DK", sequence: 1,
    latitude: null, longitude: null, scheduledArrival: "2026-11-16T18:40:00Z", scheduledDeparture: "2026-11-16T18:42:00Z",
    expectedArrival: "2026-11-16T18:40:00Z", expectedDeparture: "2026-11-16T18:42:00Z",
    plannedPlatform: null, expectedPlatform: null, platformSource: null, platformObservedAt: null, passed: false, cancelled: false }],
});
const observation = (extra: Partial<PlatformObservation>): PlatformObservation => ({ stopSequence: 1,
  stationId: snapshot().stops[0]!.stationId, source: "Rejseplanen SIRI-ET (DSB)", observedAt: "2026-11-16T18:35:07.000Z", ...extra });
const enrich = (base: TripSnapshot, observations: PlatformObservation[]) => new TripSnapshotEnricher([{
  sourceName: "Rejseplanen SIRI-ET (DSB)", supportedCountryCodes: new Set(["DK"]), platformUpdates: async () => observations,
}]).enrich(base);
afterEach(() => vi.useRealTimers());

describe("independent expected-time publisher evidence", () => {
  it("retains original timing clocks without inventing a platform observation", async () => {
    vi.useFakeTimers({ toFake: ["Date"] }); vi.setSystemTime(at);
    const result = await enrich(snapshot(), [observation({ expectedArrival: "2026-11-16T19:00:00Z", expectedDeparture: "2026-11-16T19:02:00Z" })]);
    expect(result.stops[0]).toMatchObject({
      expectedArrivalEvidence: { source: "Rejseplanen SIRI-ET (DSB)", observedAt: "2026-11-16T18:35:07.000Z" },
      expectedDepartureEvidence: { source: "Rejseplanen SIRI-ET (DSB)", observedAt: "2026-11-16T18:35:07.000Z" },
      platformSource: null, platformObservedAt: null,
    });
    expect(result.stops[0]?.arrivalObservedAt).toBeUndefined(); expect(result.stops[0]?.passageObservedAt).toBeUndefined();
  });

  it("does not renew omitted arrival evidence when a later departure-only update arrives", async () => {
    vi.useFakeTimers({ toFake: ["Date"] }); vi.setSystemTime(at);
    const first = await enrich(snapshot(), [observation({ expectedArrival: "2026-11-16T19:00:00Z", expectedDeparture: "2026-11-16T19:02:00Z" })]);
    vi.setSystemTime("2026-11-16T18:37:00Z"); first.fetchedAt = new Date().toISOString();
    const second = await enrich(first, [observation({ expectedDeparture: "2026-11-16T19:03:00Z", observedAt: "2026-11-16T18:36:30Z" })]);
    expect(second.stops[0]?.expectedArrivalEvidence).toEqual(first.stops[0]?.expectedArrivalEvidence);
    expect(second.stops[0]?.expectedDepartureEvidence).toEqual({ source: "Rejseplanen SIRI-ET (DSB)", observedAt: "2026-11-16T18:36:30Z" });
    expect(second.stops[0]?.expectedArrival).toBe("2026-11-16T19:00:00Z");
  });

  it.each(["not-a-clock", "2026-11-16T18:36:00.001Z"])("rejects timing updates with invalid or future observation clock %s", async observedAt => {
    vi.useFakeTimers({ toFake: ["Date"] }); vi.setSystemTime(at);
    const base = snapshot();
    expect((await enrich(base, [observation({ expectedDeparture: "2026-11-16T19:03:00Z", observedAt })])).stops[0]).toEqual(base.stops[0]);
  });

  it("keeps a base estimate unqualified, and clears evidence when a publisher withdraws its forecast", async () => {
    vi.useFakeTimers({ toFake: ["Date"] }); vi.setSystemTime(at);
    const base = snapshot();
    expect((await enrich(base, [observation({ expectedPlatform: "4" })])).stops[0]?.expectedDepartureEvidence).toBeUndefined();
    const qualified = await enrich(base, [observation({ expectedDeparture: "2026-11-16T19:03:00Z" })]);
    const cleared = await enrich(qualified, [observation({ expectedDeparture: null, observedAt: at })]);
    expect(cleared.stops[0]?.expectedDeparture).toBeNull(); expect(cleared.stops[0]?.expectedDepartureEvidence).toBeUndefined();
  });

  it("does not roll a qualified component back to an older redelivered observation", async () => {
    vi.useFakeTimers({ toFake: ["Date"] }); vi.setSystemTime(at);
    const first = await enrich(snapshot(), [observation({ expectedDeparture: "2026-11-16T19:03:00Z", observedAt: "2026-11-16T18:35:50Z" })]);
    const replay = await enrich(first, [observation({ expectedDeparture: "2026-11-16T19:01:00Z" })]);
    expect(replay.stops[0]?.expectedDeparture).toBe(first.stops[0]?.expectedDeparture);
    expect(replay.stops[0]?.expectedDepartureEvidence).toEqual(first.stops[0]?.expectedDepartureEvidence);
  });

  it.each(["invalid-clock", "2026-11-16T18:36:00.001Z"])("does not erase pre-existing invalid provenance %s into the unqualified base-provider fallback", async observedAt => {
    vi.useFakeTimers({ toFake: ["Date"] }); vi.setSystemTime(at);
    const base = snapshot(); base.stops[0]!.expectedDeparture = "2026-11-16T19:03:00Z";
    base.stops[0]!.expectedDepartureEvidence = { source: "Rejseplanen SIRI-ET (DSB)", observedAt };
    const result = await enrich(base, [observation({ expectedPlatform: "4", observedAt: at })]);
    expect(result.stops[0]?.expectedDepartureEvidence).toEqual(base.stops[0]?.expectedDepartureEvidence);
  });

  it("preserves older source evidence literally when fetchedAt advances, rather than making it fresh", async () => {
    vi.useFakeTimers({ toFake: ["Date"] }); vi.setSystemTime(at);
    const first = await enrich(snapshot(), [observation({ expectedDeparture: "2026-11-16T19:03:00Z" })]);
    vi.setSystemTime("2026-11-16T18:50:00Z"); first.fetchedAt = new Date().toISOString();
    const later = await enrich(first, [observation({ expectedPlatform: "7", observedAt: new Date().toISOString() })]);
    expect(later.stops[0]?.expectedDepartureEvidence).toEqual(first.stops[0]?.expectedDepartureEvidence);
    expect(later.stops[0]?.expectedDepartureEvidence?.observedAt).not.toBe(later.fetchedAt);
    const absent = await enrich(first, []);
    expect(absent.stops[0]?.expectedDepartureEvidence).toEqual(first.stops[0]?.expectedDepartureEvidence);
  });
});
