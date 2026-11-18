import { describe, expect, it } from "vitest";
import { RenfeLongDistancePositions } from "../src/providers/renfe-long-distance-positions.js";
import { ldSnapshot, ldUpdate, ldVehicles, start } from "./renfe-long-distance-fixtures.js";

describe("Renfe LD publication and movement evidence", () => {
  it.each([3_600_000, 7_200_000])("recovers moving coordinates with a %i ms clock defect and retains provenance", (offset) => {
    const recovery = new RenfeLongDistancePositions();
    expect(recovery.positions(ldVehicles(start, -3, offset), ldUpdate(), ldSnapshot(), new Date(start))).toEqual([]);
    const at = start + 30_000;
    const positions = recovery.positions(ldVehicles(at, -2.99, offset), ldUpdate(at), ldSnapshot(), new Date(at));
    expect(positions).toEqual([expect.objectContaining({ latitude: 40, longitude: -2.99, source: "real",
      asOf: new Date(at).toISOString(), providerReportedAt: new Date(at - offset).toISOString(),
      timestampBasis: "feed-publication-and-movement" })]);
  });

  it("still requires movement when the publisher fixes its header clock", () => {
    const recovery = new RenfeLongDistancePositions();
    expect(recovery.positions(ldVehicles(start, -3, 0), ldUpdate(), ldSnapshot(), new Date(start))).toEqual([]);
    const at = start + 30_000;
    const positions = recovery.positions(ldVehicles(at, -2.99, 0), ldUpdate(at), ldSnapshot(), new Date(at));
    expect(positions[0]?.asOf).toBe(new Date(at).toISOString());
    expect(positions[0]?.timestampBasis).toBeUndefined();
  });

  it.each(["missing-modified", "old-modified", "future-modified", "missing-companion", "old-companion", "foreign-feed", "half-hour", "three-hours", "negative-offset"])("rejects %s", (failure) => {
    const recovery = new RenfeLongDistancePositions();
    recovery.positions(ldVehicles(), ldUpdate(), ldSnapshot(), new Date(start));
    const at = start + 30_000, feed = ldVehicles(at, -2.99), update = ldUpdate(at);
    if (failure === "missing-modified") feed.transport!.lastModified = null;
    if (failure === "old-modified") feed.transport!.lastModified = at - 180_000;
    if (failure === "future-modified") feed.transport!.lastModified = at + 120_000;
    if (failure === "missing-companion") delete update.feed.transport;
    if (failure === "old-companion") update.observedAt = new Date(at - 180_000);
    if (failure === "foreign-feed") feed.transport!.url = "https://example.test/vehicle_positions_LD.json";
    if (failure === "half-hour") feed.header.timestamp = String((at - 1_800_000) / 1_000);
    if (failure === "three-hours") feed.header.timestamp = String((at - 10_800_000) / 1_000);
    if (failure === "negative-offset") feed.header.timestamp = String((at + 3_600_000) / 1_000);
    expect(recovery.positions(feed, update, ldSnapshot(), new Date(at))).toEqual([]);
  });

  it("never refreshes the observation time of frozen coordinates", () => {
    const recovery = new RenfeLongDistancePositions();
    recovery.positions(ldVehicles(), ldUpdate(), ldSnapshot(), new Date(start));
    recovery.positions(ldVehicles(start + 30_000, -2.99), ldUpdate(start + 30_000), ldSnapshot(), new Date(start + 30_000));
    for (const seconds of [60, 120, 180, 210]) {
      const at = start + seconds * 1_000;
      expect(recovery.positions(ldVehicles(at, -2.99), ldUpdate(at), ldSnapshot(), new Date(at))[0]?.asOf)
        .toBe(new Date(start + 30_000).toISOString());
    }
    const at = start + 240_000;
    expect(recovery.positions(ldVehicles(at, -2.99), ldUpdate(at), ldSnapshot(), new Date(at))).toEqual([]);
  });

  it.each(["cancelled", "wrong-day", "stale", "invalid"])("does not retain movement from a rejected %s record", (failure) => {
    const recovery = new RenfeLongDistancePositions();
    recovery.positions(ldVehicles(), ldUpdate(), ldSnapshot(), new Date(start));
    const at = start + 30_000, bad = ldVehicles(at, -2.99), vehicle = bad.entity[0]!.vehicle!;
    if (failure === "cancelled") vehicle.trip.scheduleRelationship = "CANCELED";
    if (failure === "wrong-day") vehicle.trip.startDate = "20261112";
    if (failure === "stale") vehicle.timestamp = String((at - 3_600_000) / 1_000);
    if (failure === "invalid") vehicle.timestamp = "invalid";
    expect(recovery.positions(bad, ldUpdate(at), ldSnapshot(), new Date(at))).toEqual([]);
    expect(recovery.positions(ldVehicles(at + 30_000, -2.99), ldUpdate(at + 30_000), ldSnapshot(), new Date(at + 30_000))).toEqual([]);
  });

  it("rejects changing coordinates under an unchanged generation instead of bypassing the speed bound", () => {
    const recovery = new RenfeLongDistancePositions();
    recovery.positions(ldVehicles(), ldUpdate(), ldSnapshot(), new Date(start));
    const at = start + 30_000;
    expect(recovery.positions(ldVehicles(at, -2.99), ldUpdate(at), ldSnapshot(), new Date(at))).toHaveLength(1);
    expect(recovery.positions(ldVehicles(at, -2.8), ldUpdate(at), ldSnapshot(), new Date(at))).toEqual([]);
  });

  it.each(["stale-vehicle", "invalid-vehicle-time", "duplicate", "cancelled", "cancelled-vehicle", "wrong-day", "hour-old-location", "teleport", "frozen-header"])("rejects %s despite a fresh file", (failure) => {
    const recovery = new RenfeLongDistancePositions();
    recovery.positions(ldVehicles(), ldUpdate(), ldSnapshot(), new Date(start));
    const at = start + 30_000, feed = ldVehicles(at, -2.99), update = ldUpdate(at);
    if (failure === "stale-vehicle") feed.entity[0]!.vehicle!.timestamp = String((at - 3_600_000) / 1_000);
    if (failure === "invalid-vehicle-time") feed.entity[0]!.vehicle!.timestamp = "invalid";
    if (failure === "duplicate") feed.entity.push(feed.entity[0]!);
    if (failure === "cancelled") update.cancelled = true;
    if (failure === "cancelled-vehicle") feed.entity[0]!.vehicle!.trip.scheduleRelationship = "CANCELED";
    if (failure === "wrong-day") feed.entity[0]!.vehicle!.trip.startDate = "20261112";
    if (failure === "hour-old-location") feed.entity[0]!.vehicle!.position!.longitude = -3.99;
    if (failure === "teleport") feed.entity[0]!.vehicle!.position!.longitude = -1;
    if (failure === "frozen-header") feed.header.timestamp = String((start - 3_600_000) / 1_000);
    expect(recovery.positions(feed, update, ldSnapshot(), new Date(at))).toEqual([]);
  });
});
