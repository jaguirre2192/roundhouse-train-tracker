import { describe, expect, it, vi } from "vitest";
import { plausibleRenfeDelay, renfeLongDistanceObservations, verifiedRenfeUpdate,
  type RenfeIdentityVerifier } from "../src/providers/renfe-long-distance-timing.js";
import { RenfePlatformOverlay } from "../src/providers/renfe.js";
import { renfeLongDistanceUpdatesURL, renfeLongDistanceVehicleURL } from "../src/providers/renfe-realtime-models.js";
import { ldSnapshot, ldUpdate, ldVehicles, start, tripId } from "./renfe-long-distance-fixtures.js";

const verified: RenfeIdentityVerifier = { verify: async (snapshot, descriptor) => ({
  tripId: descriptor.tripId, serviceDate: snapshot.serviceDate, startDate: snapshot.serviceDate.replaceAll("-", ""),
  routeId: "route", matchedStops: snapshot.stops.length, staticFetchedAt: new Date(start).toISOString(),
}) };

describe("Renfe LD delay recovery", () => {
  it("uses a reported delay after independent static verification, never the broken absolute event", async () => {
    const input = ldUpdate(); input.update.delay = 480;
    input.update.stopTimeUpdate![0]!.arrival!.delay = 480;
    const selected = await verifiedRenfeUpdate([input.feed], ldSnapshot(), verified, new Date(start));
    const observations = renfeLongDistanceObservations(selected, ldSnapshot());
    expect(observations.at(-1)).toMatchObject({ expectedArrival: "2026-11-13T19:08:00.000Z",
      source: "Renfe GTFS-RT (reported trip delay)" });
    expect(observations.every((value) => value.passed === undefined && value.arrivalObservedAt === undefined)).toBe(true);
  });

  it("requires the independent current static route match even for exact trip IDs", async () => {
    const verifier = { verify: vi.fn(async () => null) };
    const result = await verifiedRenfeUpdate([ldUpdate().feed], ldSnapshot(), verifier, new Date(start));
    expect(verifier.verify).toHaveBeenCalledOnce();
    expect(result).toBeNull();
  });

  it.each([-20_820, -301, 21_601, Infinity, "not a delay", "", null, undefined])("rejects implausible/missing delay %s", async (delay) => {
    expect(plausibleRenfeDelay(delay)).toBeNull();
    const input = ldUpdate(); input.update.delay = delay as number;
    expect(await verifiedRenfeUpdate([input.feed], ldSnapshot(), verified, new Date(start))).toBeNull();
  });

  it.each([0, -300, 6_300, 21_600])("retains a plausible explicit delay of %s seconds", (delay) => {
    expect(plausibleRenfeDelay(delay)).toBe(delay);
  });

  it("rejects a conflicting cancellation before filtering out its delay-less record", async () => {
    const input = ldUpdate();
    input.feed.entity.push({ tripUpdate: { trip: { tripId, scheduleRelationship: "CANCELED" } } });
    expect(await verifiedRenfeUpdate([input.feed], ldSnapshot(), verified, new Date(start))).toBeNull();
  });

  it("preserves independently identified cancellation with no delay", async () => {
    const input = ldUpdate(); delete input.update.delay; input.update.trip.scheduleRelationship = "CANCELED";
    const selected = await verifiedRenfeUpdate([input.feed], ldSnapshot(), verified, new Date(start));
    expect(renfeLongDistanceObservations(selected, ldSnapshot())).toHaveLength(3);
    expect(renfeLongDistanceObservations(selected, ldSnapshot()).every((value) => value.cancelled)).toBe(true);
  });

  it("rejects contradictory duplicate calls rather than declaring a station skipped", async () => {
    const input = ldUpdate();
    input.update.stopTimeUpdate!.push({ stopId: "3", scheduleRelationship: "SKIPPED" });
    expect(await verifiedRenfeUpdate([input.feed], ldSnapshot(), verified, new Date(start))).toBeNull();
  });

  it("does not attach yesterday's overnight feed record to today's future departure", async () => {
    const now = new Date("2026-11-13T23:15:00Z");
    const today = ldSnapshot(); today.serviceDate = "2026-11-14";
    today.stops = today.stops.map((stop) => ({ ...stop,
      scheduledArrival: stop.scheduledArrival?.replace("2026-11-13", "2026-11-14") ?? null,
      scheduledDeparture: stop.scheduledDeparture?.replace("2026-11-13", "2026-11-14") ?? null }));
    expect(await verifiedRenfeUpdate([ldUpdate(now.getTime()).feed], today, verified, now)).toBeNull();
  });

  it("rejects old entity timestamps even under a fresh header", async () => {
    const input = ldUpdate(); input.update.timestamp = String((start - 300_000) / 1_000);
    expect(await verifiedRenfeUpdate([input.feed], ldSnapshot(), verified, new Date(start))).toBeNull();
  });

  it("rejects reused templates for tomorrow but permits a proven overnight run", async () => {
    const snapshot = ldSnapshot(); snapshot.serviceDate = "2026-11-14";
    snapshot.stops = snapshot.stops.map((stop) => ({ ...stop,
      scheduledArrival: stop.scheduledArrival?.replace("2026-11-13", "2026-11-14") ?? null,
      scheduledDeparture: stop.scheduledDeparture?.replace("2026-11-13", "2026-11-14") ?? null }));
    expect(await verifiedRenfeUpdate([ldUpdate().feed], snapshot, verified, new Date(start))).toBeNull();
    const midnight = Date.parse("2026-11-13T23:15:00Z");
    const overnight = ldSnapshot();
    overnight.stops = overnight.stops.map((stop, index) => ({ ...stop,
      scheduledArrival: index === 0 ? null : new Date(midnight + (index - 1) * 3_600_000).toISOString(),
      scheduledDeparture: index === 2 ? null : new Date(midnight + (index - 1) * 3_600_000).toISOString() }));
    expect(await verifiedRenfeUpdate([ldUpdate(midnight).feed], overnight, verified, new Date(midnight))).not.toBeNull();
  });

  it("keeps corrected delay estimates when the independent position feed has an unexplained clock", async () => {
    const input = ldUpdate(); input.update.delay = 600;
    const overlay = new RenfePlatformOverlay(renfeLongDistanceVehicleURL, async (url) =>
      Response.json(String(url) === renfeLongDistanceUpdatesURL ? input.feed : ldVehicles(start, -3, 1_800_000),
        { headers: { "last-modified": new Date(start).toUTCString() } }), () => new Date(start),
    { tripUpdateFeedUrls: [renfeLongDistanceUpdatesURL], staticIdentityVerifier: verified });
    expect((await overlay.timingOverlay.platformUpdates(ldSnapshot())).at(-1)?.expectedArrival).toBe("2026-11-13T19:10:00.000Z");
    expect(await overlay.positionUpdates(ldSnapshot())).toEqual([]);
  });
});
