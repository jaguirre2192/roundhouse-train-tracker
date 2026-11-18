import { describe, expect, it } from "vitest";
import { diffSnapshots } from "../src/domain/events.js";
import { defaultPushPreferences, type TripSnapshot } from "../src/domain/snapshot.js";
import { OebbInfoToGoOverlay, type OebbInfoToGoBoard } from "../src/providers/oebb-infotogo.js";

function trip(): TripSnapshot {
  return {
    id: "eu:transitous:oebb-rjx-664",
    source: "transitous",
    nativeId: "oebb-rjx-664",
    serviceDate: "2026-07-21",
    operatorName: "ÖBB",
    product: "RJX 664",
    headsign: "Salzburg Hbf",
    fetchedAt: "2026-07-21T16:26:00.000Z",
    alertIds: [],
    stops: [{
      stationId: "at:transitous:wien-hbf",
      stationName: "Wien Hbf",
      countryCode: "AT",
      latitude: 48.18519,
      longitude: 16.376413,
      sequence: 1,
      scheduledArrival: null,
      scheduledDeparture: "2026-07-21T16:31:00.000Z",
      expectedArrival: null,
      expectedDeparture: "2026-07-21T16:31:00.000Z",
      plannedPlatform: "8",
      expectedPlatform: "8",
      platformSource: "Transitous",
      platformObservedAt: null,
      cancelled: false,
      passed: false,
    }],
  };
}

function liveBoard(overrides: Partial<NonNullable<OebbInfoToGoBoard["departures"]>[number]> = {}): OebbInfoToGoBoard {
  return {
    departures: [{
      id: "RJX|664|2026-07-21T18:31:00+02:00",
      train: "664",
      line: "RJX 664",
      product: "RJX",
      scheduled: "2026-07-21T18:31:00+02:00",
      expected: "2026-07-21T18:37:00+02:00",
      track: "9",
      destination: { default: "Salzburg Hbf" },
      flags: ["TRACKCHANGE"],
      ...overrides,
    }],
    specialNotices: [{
      type: "CONSTRUCTION",
      flags: ["ANNOUNCEMENT"],
      text: { default: "Bauarbeiten zwischen Wien und Salzburg" },
    }],
  };
}

describe("ÖBB InfoToGo overlay", () => {
  it("still checks the upcoming station when a recent passed anchor has no matching board", async () => {
    const current = trip();
    current.stops.unshift({ ...current.stops[0]!, stationId: "unknown", stationName: "Unknown", latitude: 0, longitude: 0,
      sequence: 0, passed: true, scheduledDeparture: "2026-07-21T16:00:00Z", expectedDeparture: "2026-07-21T16:00:00Z" });
    const overlay = new OebbInfoToGoOverlay(async () => liveBoard(), () => new Date(current.fetchedAt));
    expect(await overlay.platformUpdates(current)).toContainEqual(expect.objectContaining({ stationId: "at:transitous:wien-hbf", expectedPlatform: "9" }));
  });

  it("maps the official expected time, current platform, and route notice once", async () => {
    const requestedStationIds: string[] = [];
    const overlay = new OebbInfoToGoOverlay(async (stationId) => {
      requestedStationIds.push(stationId);
      return liveBoard();
    }, () => new Date("2026-07-21T16:26:30.000Z"));

    const observations = await overlay.platformUpdates(trip());
    const alerts = await overlay.tripAlertIds(trip());

    expect(requestedStationIds).toEqual(["8101003"]);
    expect(observations).toEqual([expect.objectContaining({
      stopSequence: 1,
      expectedPlatform: "9",
      expectedDeparture: "2026-07-21T16:37:00.000Z",
      cancelled: false,
      source: "ÖBB InfoToGo",
    })]);
    expect(alerts).toEqual([expect.stringMatching(/^oebb:notice:[0-9a-f]{24}$/u)]);
  });

  it("drives deduplicatable platform, delay, and disruption notifications", async () => {
    const overlay = new OebbInfoToGoOverlay(async () => liveBoard(),
      () => new Date("2026-07-21T16:26:30.000Z"));
    const previous = trip();
    const observations = await overlay.platformUpdates(previous);
    const alertIds = await overlay.tripAlertIds(previous);
    const observation = observations[0]!;
    const current: TripSnapshot = {
      ...previous,
      fetchedAt: observation.observedAt,
      alertIds,
      stops: [{
        ...previous.stops[0]!,
        expectedDeparture: observation.expectedDeparture ?? null,
        expectedPlatform: observation.expectedPlatform ?? null,
        platformSource: observation.source,
        platformObservedAt: observation.observedAt,
        cancelled: observation.cancelled ?? false,
      }],
    };

    const first = diffSnapshots(previous, current, defaultPushPreferences);
    const second = diffSnapshots(previous, current, defaultPushPreferences);

    expect(first.map((event) => event.kind)).toEqual([
      "platform-change",
      "delay-threshold",
      "disruption",
    ]);
    expect(first.map((event) => event.fingerprint)).toEqual(second.map((event) => event.fingerprint));
  });

  it("requests a terminal arrival board and preserves its expected arrival and platform", async () => {
    const current = trip();
    current.stops[0]!.scheduledArrival = current.stops[0]!.scheduledDeparture;
    current.stops[0]!.scheduledDeparture = null;
    current.stops[0]!.expectedDeparture = null;
    const kinds: Array<string | undefined> = [];
    const overlay = new OebbInfoToGoOverlay(async (_stationId, kind) => {
      kinds.push(kind);
      const arrival = liveBoard().departures![0]!;
      return { arrivals: [{ ...arrival, destination: null, origin: { default: "Uzhhorod" } }] };
    });
    const values = await overlay.platformUpdates(current);
    expect(kinds).toEqual(["arrival"]);
    expect(values).toEqual([expect.objectContaining({ expectedArrival: "2026-07-21T16:37:00.000Z", expectedPlatform: "9" })]);
    expect(values[0]?.expectedDeparture).toBeUndefined();
  });

  it("does not use a departure board as proof of a terminal arrival", async () => {
    const current = trip();
    current.stops[0]!.scheduledArrival = current.stops[0]!.scheduledDeparture;
    current.stops[0]!.scheduledDeparture = null;
    expect(await new OebbInfoToGoOverlay(async () => liveBoard()).platformUpdates(current)).toEqual([]);
  });

  it("maps official cancellation flags", async () => {
    const overlay = new OebbInfoToGoOverlay(async () => liveBoard({ flags: ["CANCELED"] }));

    expect(await overlay.platformUpdates(trip())).toEqual([
      expect.objectContaining({ cancelled: true }),
    ]);
  });

  it("does not publish the provider's missing-track placeholder as a platform", async () => {
    const overlay = new OebbInfoToGoOverlay(async () =>
      liveBoard({ track: "-", flags: ["CANCELED"] })
    );

    expect(await overlay.platformUpdates(trip())).toEqual([
      expect.not.objectContaining({ expectedPlatform: "-" }),
    ]);
  });

  it("rejects an ambiguous same-time movement instead of guessing", async () => {
    const board = liveBoard();
    board.departures = [board.departures![0]!, { ...board.departures![0]!, id: "duplicate" }];
    const overlay = new OebbInfoToGoOverlay(async () => board);

    expect(await overlay.platformUpdates(trip())).toEqual([]);
    expect(await overlay.tripAlertIds(trip())).toEqual([]);
  });
});
