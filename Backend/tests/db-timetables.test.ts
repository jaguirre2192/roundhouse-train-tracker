import { describe, expect, it } from "vitest";
import { defaultPushPreferences, type TripSnapshot } from "../src/domain/snapshot.js";
import { diffSnapshots } from "../src/domain/events.js";
import { DBTimetablesOverlay } from "../src/providers/db-timetables.js";
import { TripSnapshotEnricher } from "../src/providers/platform-overlay.js";

function trip(): TripSnapshot {
  return {
    id: "eu:transitous:ice-742",
    source: "transitous",
    nativeId: "ice-742",
    serviceDate: "2026-07-21",
    operatorName: "DB Fernverkehr AG",
    product: "ICE 742",
    headsign: "Münster Hbf",
    fetchedAt: "2026-07-21T16:10:00.000Z",
    alertIds: [],
    stops: [{
      stationId: "eu:transitous:berlin-hbf",
      stationName: "S+U Berlin Hauptbahnhof",
      countryCode: "DE",
      latitude: 52.525,
      longitude: 13.369,
      sequence: 2,
      scheduledArrival: "2026-07-21T16:12:00.000Z",
      scheduledDeparture: "2026-07-21T16:16:00.000Z",
      expectedArrival: "2026-07-21T16:12:00.000Z",
      expectedDeparture: "2026-07-21T16:16:00.000Z",
      plannedPlatform: null,
      expectedPlatform: null,
      platformSource: null,
      platformObservedAt: null,
      cancelled: false,
      passed: false,
    }],
  };
}

function fixtureFetcher(requests: Request[]): typeof fetch {
  return async (input, init) => {
    const request = new Request(input, init);
    requests.push(request);
    const path = new URL(request.url).pathname;
    if (path.includes("/station/")) {
      if (path.endsWith("Berlin%20Hauptbahnhof")) return new Response("<stations></stations>");
      return new Response(`<stations><station name="Berlin Hbf" eva="8098160" ds100="BL" db="true"/></stations>`);
    }
    if (path.includes("/plan/8098160/260721/18")) {
      return new Response(`
        <timetable station="Berlin Hbf">
          <s id="ice-742-stop-2">
            <tl c="ICE" n="742" o="80" t="p"/>
            <ar pt="2607211812" pp="8" fb="ICE 742"/>
            <dp pt="2607211816" pp="8" fb="ICE 742"/>
          </s>
        </timetable>
      `);
    }
    if (path.endsWith("/fchg/8098160")) {
      return new Response(`
        <timetable station="Berlin Hbf" eva="8098160">
          <s id="ice-742-stop-2" eva="8098160">
            <dp ct="2607211821" cp="11" cs="p">
              <m id="r-delay-742" t="d" c="48" ts="2607211809"/>
            </dp>
          </s>
        </timetable>
      `);
    }
    return new Response("not found", { status: 404 });
  };
}

describe("DB Timetables overlay", () => {
  it("joins official changed times and platforms to a Transitous trip", async () => {
    const requests: Request[] = [];
    const overlay = new DBTimetablesOverlay(
      "client-id",
      "api-key",
      "https://db.test/timetables/v1",
      fixtureFetcher(requests),
      () => new Date("2026-07-21T16:10:00.000Z"),
    );

    const observations = await overlay.platformUpdates(trip());
    const alertIds = await overlay.tripAlertIds(trip());

    expect(observations).toEqual([expect.objectContaining({
      stopSequence: 2,
      plannedPlatform: "8",
      expectedPlatform: "11",
      expectedDeparture: "2026-07-21T16:21:00.000Z",
      cancelled: false,
      source: "DB Timetables",
    })]);
    expect(alertIds).toEqual(["db:r-delay-742"]);
    expect(requests.filter((request) => request.url.includes("/plan/"))).toHaveLength(1);
    expect(requests.filter((request) => request.url.includes("/fchg/"))).toHaveLength(1);
    expect(requests.every((request) => request.headers.get("DB-Client-Id") === "client-id")).toBe(true);
    expect(requests.every((request) => request.headers.get("DB-Api-Key") === "api-key")).toBe(true);

    const previous = trip();
    previous.stops[0] = { ...previous.stops[0]!, plannedPlatform: "8", expectedPlatform: "8" };
    const current = await new TripSnapshotEnricher([overlay]).enrich(previous);
    const events = diffSnapshots(previous, current, defaultPushPreferences);
    expect(events).toEqual(expect.arrayContaining([
      expect.objectContaining({ kind: "platform-change", oldValue: "8", newValue: "11" }),
      expect.objectContaining({ kind: "delay-threshold", newValue: "5" }),
      expect.objectContaining({ kind: "disruption", newValue: "db:r-delay-742" }),
    ]));
  });

  it("retains both arrival and departure changes from the same identified station call", async () => {
    const fetcher = fixtureFetcher([]);
    const overlay = new DBTimetablesOverlay("client", "key", "https://db.test/timetables/v1", async (input, init) => {
      const response = await fetcher(input, init);
      if (!String(input).includes("/fchg/")) return response;
      return new Response((await response.text()).replace('<dp ct="2607211821"', '<ar ct="2607211818" cs="p"/><dp ct="2607211821"'));
    });
    const current = await new TripSnapshotEnricher([overlay]).enrich(trip());
    expect(current.stops[0]).toMatchObject({
      expectedArrival: "2026-07-21T16:18:00.000Z", expectedDeparture: "2026-07-21T16:21:00.000Z", expectedPlatform: "11",
    });
  });

  it("maps an official cancellation without inventing a platform change", async () => {
    const overlay = new DBTimetablesOverlay(
      "client-id",
      "api-key",
      "https://db.test/timetables/v1",
      async (input, init) => {
        const request = new Request(input, init);
        const path = new URL(request.url).pathname;
        if (path.includes("/station/")) {
          return new Response(`<stations><station name="Berlin Hbf" eva="8098160" db="true"/></stations>`);
        }
        if (path.includes("/plan/")) {
          return new Response(`<timetable><s id="ice-742-stop-2"><tl c="ICE" n="742"/><dp pt="2607211816" pp="8"/></s></timetable>`);
        }
        return new Response(`<timetable><s id="ice-742-stop-2"><dp cs="c"/></s></timetable>`);
      },
      () => new Date("2026-07-21T16:10:00.000Z"),
    );

    expect(await overlay.platformUpdates(trip())).toEqual([expect.objectContaining({
      expectedPlatform: "8",
      cancelled: true,
    })]);
  });

  it("retains DB provenance for the most recently passed stop so it can become training truth", async () => {
    const requests: Request[] = [];
    const overlay = new DBTimetablesOverlay(
      "client-id",
      "api-key",
      "https://db.test/timetables/v1",
      fixtureFetcher(requests),
      () => new Date("2026-07-21T16:25:00.000Z"),
    );
    const completed = trip();
    completed.fetchedAt = "2026-07-21T16:25:00.000Z";
    completed.stops[0] = {
      ...completed.stops[0]!,
      passed: true,
    };

    expect(await overlay.platformUpdates(completed)).toEqual([expect.objectContaining({
      stopSequence: 2,
      plannedPlatform: "8",
      expectedPlatform: "11",
      source: "DB Timetables",
    })]);
    expect(requests.filter((request) => request.url.includes("/plan/"))).toHaveLength(1);
    expect(requests.filter((request) => request.url.includes("/fchg/"))).toHaveLength(1);
  });
});
