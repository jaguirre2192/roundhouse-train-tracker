import { describe, expect, it } from "vitest";
import { diffSnapshots } from "../src/domain/events.js";
import { defaultPushPreferences, type TripSnapshot } from "../src/domain/snapshot.js";

function snapshot(overrides: Partial<TripSnapshot["stops"][number]> = {}): TripSnapshot {
  return {
    id: "us:amtraker:171-20",
    source: "amtraker",
    nativeId: "171-20",
    serviceDate: "2026-07-20",
    operatorName: "Amtrak",
    product: "Northeast Regional 171",
    headsign: "Philadelphia",
    fetchedAt: "2026-07-20T16:00:00.000Z",
    alertIds: [],
    stops: [{
      stationId: "us:amtraker:NYP",
      stationName: "New York Penn",
      countryCode: "US",
      latitude: 40.7506,
      longitude: -73.9935,
      sequence: 1,
      scheduledArrival: null,
      scheduledDeparture: "2026-07-20T16:05:00.000Z",
      expectedArrival: null,
      expectedDeparture: "2026-07-20T16:07:00.000Z",
      plannedPlatform: "8",
      expectedPlatform: "8",
      platformSource: "Amtraker",
      platformObservedAt: null,
      cancelled: false,
      passed: false,
      ...overrides,
    }],
  };
}

describe("diffSnapshots", () => {
  it("does not notify for the first observation", () => {
    expect(diffSnapshots(null, snapshot(), defaultPushPreferences)).toEqual([]);
  });

  it("emits a stable platform-change event", () => {
    const current = snapshot({ expectedPlatform: "9" });
    const first = diffSnapshots(snapshot(), current, defaultPushPreferences);
    const second = diffSnapshots(snapshot(), current, defaultPushPreferences);

    expect(first).toHaveLength(1);
    expect(first[0]).toMatchObject({ kind: "platform-change", oldValue: "8", newValue: "9" });
    expect(first[0]?.fingerprint).toBe(second[0]?.fingerprint);
  });

  it("notifies when an official platform is assigned for the first time", () => {
    const previous = snapshot({ plannedPlatform: null, expectedPlatform: null });
    const current = snapshot({
      plannedPlatform: null,
      expectedPlatform: "9",
      platformObservedAt: "2026-07-20T16:00:10.000Z",
    });

    const events = diffSnapshots(previous, current, defaultPushPreferences);

    expect(events).toContainEqual(expect.objectContaining({
      kind: "platform-change",
      oldValue: null,
      newValue: "9",
      title: "Track assigned at New York Penn",
    }));
  });

  it("notifies when delay crosses the configured threshold", () => {
    const events = diffSnapshots(
      snapshot(),
      snapshot({ expectedDeparture: "2026-07-20T16:12:00.000Z" }),
      defaultPushPreferences,
    );
    expect(events).toContainEqual(expect.objectContaining({ kind: "delay-threshold", newValue: "7" }));
  });

  it("notifies when a stop becomes cancelled", () => {
    const events = diffSnapshots(snapshot(), snapshot({ cancelled: true }), defaultPushPreferences);
    expect(events).toContainEqual(expect.objectContaining({ kind: "cancellation" }));
  });

  it("collapses a whole-trip cancellation into one notification", () => {
    const previous = snapshot();
    previous.stops.push({
      ...previous.stops[0]!,
      sequence: 2,
      stationId: "us:amtraker:PHL",
      stationName: "Philadelphia 30th Street",
    });
    const current = {
      ...previous,
      fetchedAt: "2026-07-20T16:00:20.000Z",
      stops: previous.stops.map((stop) => ({ ...stop, cancelled: true })),
    };

    const events = diffSnapshots(previous, current, defaultPushPreferences);

    expect(events.filter((event) => event.kind === "cancellation")).toEqual([
      expect.objectContaining({ stopId: null, title: "Northeast Regional 171 cancelled" }),
    ]);
  });

  it("says platform outside Amtrak and track for Amtrak", () => {
    const amtrak = diffSnapshots(snapshot(), snapshot({ expectedPlatform: "9" }), defaultPushPreferences)[0];
    expect(amtrak).toMatchObject({ title: "Track changed at New York Penn",
      body: "Northeast Regional 171 now departs from track 9 (was 8)." });
    const db = (stop: Partial<TripSnapshot["stops"][number]> = {}): TripSnapshot => ({ ...snapshot(stop),
      id: "de:db:ICE-599", source: "transitous", nativeId: "ICE-599", operatorName: "DB Fernverkehr", product: "ICE 599" });
    const other = diffSnapshots(db(), db({ expectedPlatform: "9" }), defaultPushPreferences)[0];
    expect(other).toMatchObject({ title: "Platform changed at New York Penn",
      body: "ICE 599 now departs from platform 9 (was 8)." });
  });

  it("announces a platform that flips back to an earlier value", () => {
    const at = (fetchedAt: string, expectedPlatform: string) => ({ ...snapshot({ expectedPlatform }), fetchedAt });
    const a1 = at("2026-07-20T16:00:00.000Z", "8");
    const b1 = at("2026-07-20T16:01:00.000Z", "9");
    const a2 = at("2026-07-20T16:02:00.000Z", "8");
    const b2 = at("2026-07-20T16:03:00.000Z", "9");

    const first = diffSnapshots(a1, b1, defaultPushPreferences)[0];
    const last = diffSnapshots(a2, b2, defaultPushPreferences)[0];

    expect(last).toMatchObject({ kind: "platform-change", newValue: "9" });
    expect(last?.fingerprint).not.toBe(first?.fingerprint);
  });

  it("ignores stops the train has already left", () => {
    const events = diffSnapshots(
      snapshot({ passed: true }),
      snapshot({ passed: true, expectedPlatform: "9", expectedDeparture: "2026-07-20T16:30:00.000Z" }),
      defaultPushPreferences,
    );
    expect(events).toEqual([]);
  });
});
