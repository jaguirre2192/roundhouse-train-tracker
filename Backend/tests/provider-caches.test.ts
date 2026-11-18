import { describe, expect, it } from "vitest";
import type { TripSnapshot } from "../src/domain/snapshot.js";
import { DBTimetablesOverlay } from "../src/providers/db-timetables.js";
import { cachedLoad, ExpiringCache } from "../src/providers/expiring-cache.js";

describe("ExpiringCache", () => {
  it("expires entries and evicts the oldest beyond its cap", () => {
    const cache = new ExpiringCache<string>(2);
    cache.set("a", "A", 0, 1_000);
    cache.set("b", "B", 0, 1_000);
    cache.set("c", "C", 0, 1_000);

    expect(cache.size).toBe(2);
    expect(cache.get("a", 10)).toBeUndefined();
    expect(cache.get("c", 10)).toBe("C");
    expect(cache.get("c", 1_000)).toBeUndefined();
  });

  it("never replays a rejected load", async () => {
    const cache = new ExpiringCache<Promise<string>>(10);
    let calls = 0;
    const load = async () => {
      calls += 1;
      if (calls === 1) throw new Error("upstream failed");
      return "ok";
    };

    await expect(cachedLoad(cache, "key", 0, 60_000, load)).rejects.toThrow("upstream failed");
    await expect(cachedLoad(cache, "key", 1, 60_000, load)).resolves.toBe("ok");
    await expect(cachedLoad(cache, "key", 2, 60_000, load)).resolves.toBe("ok");
    expect(calls).toBe(2);
  });
});

describe("DB Timetables plan cache", () => {
  const trip: TripSnapshot = {
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
      stationName: "Berlin Hbf",
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

  it("retries a plan slice that failed instead of caching the rejection forever", async () => {
    let now = new Date("2026-07-21T16:10:00.000Z");
    let planRequests = 0;
    const overlay = new DBTimetablesOverlay("client", "key", "https://db.test/timetables/v1", async (input) => {
      const path = new URL(String(input)).pathname;
      if (path.includes("/station/")) {
        return new Response(`<stations><station name="Berlin Hbf" eva="8011160" db="true"/></stations>`);
      }
      if (path.includes("/plan/")) {
        planRequests += 1;
        if (planRequests === 1) return new Response("busy", { status: 503 });
        return new Response(`<timetable><s id="ice-742-2"><tl c="ICE" n="742"/>
          <dp pt="2607211816" pp="8"/></s></timetable>`);
      }
      return new Response("<timetable></timetable>");
    }, () => now);

    // A failed station subfeed is now isolated so other stations can still
    // contribute. Its failed plan must nevertheless be retried next refresh.
    await expect(overlay.platformUpdates(trip)).resolves.toEqual([]);
    now = new Date("2026-07-21T16:10:20.000Z");

    await expect(overlay.platformUpdates(trip)).resolves.toEqual([
      expect.objectContaining({ expectedPlatform: "8" }),
    ]);
    expect(planRequests).toBe(2);
  });
});
