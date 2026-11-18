import { transit_realtime } from "gtfs-realtime-bindings";
import { describe, expect, it } from "vitest";
import { defaultPushPreferences, type TripSnapshot } from "../src/domain/snapshot.js";
import { diffSnapshots } from "../src/domain/events.js";
import { TripSnapshotEnricher } from "../src/providers/platform-overlay.js";
import { TrafiklabSwedenRealtimeOverlay } from "../src/providers/trafiklab-sweden-realtime.js";

const feedTime = 1_785_763_200;

function trip(): TripSnapshot {
  return {
    id: "eu:transitous:trafiklab-123",
    source: "transitous",
    nativeId: "20260803_15:00_se-Trafiklab_123",
    serviceDate: "2026-08-03",
    operatorName: "SL",
    product: "Regional 40",
    headsign: "Uppsala Centralstation",
    fetchedAt: "2026-08-03T13:00:00.000Z",
    alertIds: [],
    stops: [
      {
        stationId: "eu:transitous:se-Trafiklab_740000001",
        stationName: "Stockholm Centralstation",
        countryCode: "SE",
        latitude: 59.33014,
        longitude: 18.058153,
        sequence: 1,
        scheduledArrival: null,
        scheduledDeparture: "2026-08-03T13:00:00.000Z",
        expectedArrival: null,
        expectedDeparture: "2026-08-03T13:00:00.000Z",
        plannedPlatform: null,
        expectedPlatform: null,
        platformSource: null,
        platformObservedAt: null,
        cancelled: false,
        passed: false,
      },
      {
        stationId: "eu:transitous:se-Trafiklab_740000002",
        stationName: "Uppsala Centralstation",
        countryCode: "SE",
        latitude: 59.8585,
        longitude: 17.6447,
        sequence: 2,
        scheduledArrival: "2026-08-03T13:40:00.000Z",
        scheduledDeparture: null,
        expectedArrival: "2026-08-03T13:40:00.000Z",
        expectedDeparture: null,
        plannedPlatform: null,
        expectedPlatform: null,
        platformSource: null,
        platformObservedAt: null,
        cancelled: false,
        passed: false,
      },
    ],
  };
}

function response(message: transit_realtime.IFeedMessage): Response {
  const encoded = transit_realtime.FeedMessage.encode(message).finish();
  const body = encoded.buffer.slice(encoded.byteOffset, encoded.byteOffset + encoded.byteLength) as ArrayBuffer;
  return new Response(body, {
    headers: { "content-type": "application/x-protobuf" },
  });
}

function tripFeed(): transit_realtime.IFeedMessage {
  return {
    header: { gtfsRealtimeVersion: "2.0", timestamp: feedTime },
    entity: [{
      id: "trip-123",
      tripUpdate: {
        trip: { tripId: "123", startDate: "20260803" },
        timestamp: feedTime,
        stopTimeUpdate: [
          { stopSequence: 1, stopId: "902201", departure: { delay: 360 } },
          {
            stopSequence: 2,
            stopId: "902202",
            arrival: { time: feedTime + 2_520 },
            scheduleRelationship: transit_realtime.TripUpdate.StopTimeUpdate.ScheduleRelationship.SKIPPED,
          },
        ],
      },
    }],
  };
}

function alertFeed(): transit_realtime.IFeedMessage {
  return {
    header: { gtfsRealtimeVersion: "2.0", timestamp: feedTime },
    entity: [{
      id: "alert-7",
      alert: {
        activePeriod: [{ start: feedTime - 60, end: feedTime + 3_600 }],
        informedEntity: [{ trip: { tripId: "123", startDate: "20260803" } }],
      },
    }],
  };
}

function vehicleFeed(): transit_realtime.IFeedMessage {
  return {
    header: { gtfsRealtimeVersion: "2.0", timestamp: feedTime },
    entity: [{
      id: "vehicle-123",
      vehicle: {
        trip: { tripId: "123", startDate: "20260803" },
        position: { latitude: 59.55, longitude: 17.82, bearing: 15 },
        timestamp: feedTime,
      },
    }],
  };
}

describe("TrafiklabSwedenRealtimeOverlay", () => {
  it("does not turn an empty protobuf event into an on-time prediction over regional evidence", async () => {
    const message = tripFeed();
    message.entity![0]!.tripUpdate!.stopTimeUpdate = [{ stopSequence: 1, departure: {} }];
    const overlay = new TrafiklabSwedenRealtimeOverlay(
      "key", "https://trafiklab.test", async () => response(message),
      () => new Date(feedTime * 1_000), ["sl"],
    );
    expect(await overlay.platformUpdates(trip())).toEqual([]);
    const regional = { sourceName: "Regional", supportedCountryCodes: new Set(["SE"]),
      platformUpdates: async () => [{ stopSequence: 1, stationId: trip().stops[0]!.stationId,
        expectedDeparture: "2026-08-03T13:06:00.000Z", observedAt: "2026-08-03T12:59:30.000Z", source: "Regional" }] };
    const enriched = await new TripSnapshotEnricher([regional, overlay]).enrich(trip());
    expect(enriched.stops[0]!.expectedDeparture).toBe("2026-08-03T13:06:00.000Z");
  });

  it.each([
    [{ time: 0 }, undefined],
    [{ time: 1_000_000_000_000_000 }, undefined],
    [{ delay: 86_401 }, undefined],
    [{ delay: -86_401 }, undefined],
    [{ delay: 0 }, "2026-08-03T13:00:00.000Z"],
    [{ delay: -30 }, "2026-08-03T12:59:30.000Z"],
  ])("accepts only explicit valid bounded event values: %j", async (event, expected) => {
    const message = tripFeed();
    message.entity![0]!.tripUpdate!.stopTimeUpdate = [{ stopSequence: 1, departure: event }];
    const overlay = new TrafiklabSwedenRealtimeOverlay(
      "key", "https://trafiklab.test", async () => response(message),
      () => new Date(feedTime * 1_000), ["sl"],
    );
    const observations = await overlay.platformUpdates(trip());
    expect(observations[0]?.expectedDeparture).toBe(expected);
    if (expected === undefined) expect(observations).toEqual([]);
  });

  it("uses the approved GTFS Sweden realtime key for delays, cancellations, alerts, and positions", async () => {
    const requests: string[] = [];
    const fetcher: typeof fetch = async (input) => {
      const url = new URL(String(input));
      requests.push(url.toString());
      expect(url.searchParams.get("key")).toBe("trafiklab-key");
      if (url.pathname.includes("/skane/")) return new Response("temporarily unavailable", { status: 503 });
      if (url.pathname.endsWith("/TripUpdatesSweden.pb")) return response(tripFeed());
      if (url.pathname.endsWith("/ServiceAlertsSweden.pb")) return response(alertFeed());
      if (url.pathname.endsWith("/VehiclePositionsSweden.pb")) return response(vehicleFeed());
      return new Response("not found", { status: 404 });
    };
    const overlay = new TrafiklabSwedenRealtimeOverlay(
      "trafiklab-key",
      "https://trafiklab.test/gtfs-rt-sweden",
      fetcher,
      () => new Date(feedTime * 1_000),
      ["sl", "skane"],
    );
    const previous = trip();
    const current = await new TripSnapshotEnricher([overlay], [overlay]).enrich(previous);

    expect(current.stops[0]).toMatchObject({
      expectedDeparture: "2026-08-03T13:06:00.000Z",
      expectedPlatform: null,
    });
    expect(current.stops[1]).toMatchObject({ cancelled: true });
    expect(current.alertIds).toEqual(["trafiklab-se:sl:alert-7"]);
    expect(current.positions).toHaveLength(1);
    expect(current.positions?.[0]).toMatchObject({
      provider: "Trafiklab GTFS Sweden 3 Realtime",
    });
    expect(current.positions?.[0]?.latitude).toBeCloseTo(59.55, 4);
    expect(current.positions?.[0]?.longitude).toBeCloseTo(17.82, 4);
    expect(diffSnapshots(previous, current, defaultPushPreferences)).toEqual(expect.arrayContaining([
      expect.objectContaining({ kind: "delay-threshold", newValue: "6" }),
      expect.objectContaining({ kind: "cancellation", stopId: "eu:transitous:se-Trafiklab_740000002" }),
      expect.objectContaining({ kind: "disruption" }),
    ]));
    expect(requests.some((url) => url.includes("/sl/TripUpdatesSweden.pb"))).toBe(true);
    expect(requests.some((url) => url.includes("/sl/ServiceAlertsSweden.pb"))).toBe(true);
    expect(requests.some((url) => url.includes("/sl/VehiclePositionsSweden.pb"))).toBe(true);
  });

  it("does not query Trafiklab for a non-Swedish source trip", async () => {
    const requests: string[] = [];
    const overlay = new TrafiklabSwedenRealtimeOverlay(
      "trafiklab-key",
      "https://trafiklab.test/gtfs-rt-sweden",
      async (input) => {
        requests.push(String(input));
        return response(tripFeed());
      },
      () => new Date(feedTime * 1_000),
      ["sl"],
    );
    const other = { ...trip(), nativeId: "20260803_15:00_no-Entur_123" };
    expect(await overlay.platformUpdates(other)).toEqual([]);
    expect(requests).toEqual([]);
  });

  it("retains only the matched update and header time in the trip cache", async () => {
    const message = tripFeed();
    delete message.entity![0]!.tripUpdate!.timestamp;
    message.entity!.push({ id: "unrelated", tripUpdate: { trip: { tripId: "other" } } });
    const overlay = new TrafiklabSwedenRealtimeOverlay(
      "key", "https://trafiklab.test", async () => response(message),
      () => new Date(feedTime * 1_000 + 5_000), ["sl"],
    );
    const observations = await overlay.platformUpdates(trip());
    expect(observations[0]?.observedAt).toBe(new Date(feedTime * 1_000).toISOString());
    // Inspect the retention boundary without adding a production diagnostics API.
    const cache = Reflect.get(overlay, "tripCache") as Map<string, { value: Promise<unknown> }>;
    const retained = await cache.get(trip().id)!.value;
    expect(retained).toEqual({
      operator: "sl", feedTimestamp: new Date(feedTime * 1_000),
      update: expect.objectContaining({ trip: expect.objectContaining({ tripId: "123" }) }),
    });
    expect(Object.keys(retained as object).sort()).toEqual(["feedTimestamp", "operator", "update"]);
  });

  it("prunes expired unrelated trips while retaining fresh entries", async () => {
    let now = feedTime * 1_000;
    const overlay = new TrafiklabSwedenRealtimeOverlay(
      "key", "https://trafiklab.test", async () => response(tripFeed()),
      () => new Date(now), ["sl"],
    );
    await overlay.platformUpdates(trip());
    now += 20_000;
    await overlay.platformUpdates({ ...trip(), id: "recent" });
    now += 10_000;
    await overlay.platformUpdates({ ...trip(), id: "new" });
    const cache = Reflect.get(overlay, "tripCache") as Map<string, unknown>;
    expect([...cache.keys()]).toEqual(["recent", "new"]);
  });

  it("evicts the oldest entry at capacity without clearing the fresh cache", async () => {
    let requests = 0;
    const overlay = new TrafiklabSwedenRealtimeOverlay(
      "key", "https://trafiklab.test", async () => { requests += 1; return response(tripFeed()); },
      () => new Date(feedTime * 1_000), ["sl"],
    );
    for (let index = 0; index <= 200; index += 1) {
      await overlay.platformUpdates({ ...trip(), id: `trip-${index}` });
    }
    const cache = Reflect.get(overlay, "tripCache") as Map<string, unknown>;
    expect(cache.size).toBe(200);
    expect(cache.has("trip-0")).toBe(false);
    expect(cache.has("trip-1")).toBe(true);
    expect(cache.has("trip-200")).toBe(true);
    expect(requests).toBe(1);
  });

  it("shares an in-flight resolution and still rejects cross-operator duplicates", async () => {
    let release: (value: Response) => void = () => {};
    let requests = 0;
    const overlay = new TrafiklabSwedenRealtimeOverlay(
      "key", "https://trafiklab.test", async (input) => {
        requests += 1;
        if (String(input).includes("/sl/")) return new Promise<Response>((resolve) => { release = resolve; });
        return response(tripFeed());
      }, () => new Date(feedTime * 1_000), ["sl", "ul"],
    );
    const unknownAgency = { ...trip(), operatorName: "Unmapped source agency" };
    const first = overlay.platformUpdates(unknownAgency);
    const second = overlay.platformUpdates(unknownAgency);
    release(response(tripFeed()));
    expect(await Promise.all([first, second])).toEqual([[], []]);
    expect(requests).toBe(2);
  });

  it("scopes an exact source agency to its feed without waiting for unrelated operators", async () => {
    const requests: string[] = [];
    const overlay = new TrafiklabSwedenRealtimeOverlay("key", "https://trafiklab.test", async (input) => {
      const path = new URL(String(input)).pathname; requests.push(path);
      if (!path.includes("/sl/")) return new Promise<Response>(() => {});
      return response(tripFeed());
    }, () => new Date(feedTime * 1_000), ["sl", "skane", "ul"]);
    expect(await overlay.platformUpdates(trip())).toHaveLength(2);
    expect(requests).toEqual(["/sl/TripUpdatesSweden.pb"]);
  });

  it("does not borrow another agency's update when the scoped feed has no match", async () => {
    const requests: string[] = [];
    const overlay = new TrafiklabSwedenRealtimeOverlay("key", "https://trafiklab.test", async (input) => {
      requests.push(String(input));
      return response({ header: tripFeed().header, entity: [] });
    }, () => new Date(feedTime * 1_000), ["sl", "ul"]);
    expect(await overlay.platformUpdates(trip())).toEqual([]);
    expect(requests).toHaveLength(1);
  });

  it.each(["SJ", "Snälltåget", "VR", "Trafikverket"])("does not scan unrelated regions for static-only source %s", async (operatorName) => {
    let requests = 0;
    const overlay = new TrafiklabSwedenRealtimeOverlay("key", "https://trafiklab.test", async () => {
      requests += 1; return response(tripFeed());
    }, () => new Date(feedTime * 1_000));
    expect(await overlay.platformUpdates({ ...trip(), operatorName })).toEqual([]);
    expect(requests).toBe(0);
  });

  it("rejects duplicate updates within the source agency", async () => {
    const feed = tripFeed(); feed.entity!.push({ ...feed.entity![0]!, id: "duplicate" });
    const overlay = new TrafiklabSwedenRealtimeOverlay("key", "https://trafiklab.test", async () => response(feed),
      () => new Date(feedTime * 1_000), ["sl"]);
    expect(await overlay.platformUpdates(trip())).toEqual([]);
  });

  it("requires every source to finish successfully for an unknown agency", async () => {
    const overlay = new TrafiklabSwedenRealtimeOverlay("key", "https://trafiklab.test", async (input) => {
      return String(input).includes("/ul/") ? new Response(null, { status: 503 }) : response(tripFeed());
    }, () => new Date(feedTime * 1_000), ["sl", "ul"]);
    expect(await overlay.platformUpdates({ ...trip(), operatorName: "Unmapped source agency" })).toEqual([]);
  });

  it("accepts one unknown-agency match only after other sources explicitly contain none", async () => {
    const overlay = new TrafiklabSwedenRealtimeOverlay("key", "https://trafiklab.test", async (input) => response(
      String(input).includes("/ul/") ? { header: tripFeed().header, entity: [] } : tripFeed()),
    () => new Date(feedTime * 1_000), ["sl", "ul"]);
    expect(await overlay.platformUpdates({ ...trip(), operatorName: "Unmapped source agency" })).toHaveLength(2);
  });

  it.each([undefined, feedTime - 301, feedTime + 121])("rejects missing, stale and future feed headers (%s)", async (value) => {
    const feed = tripFeed();
    if (value === undefined) delete feed.header.timestamp; else feed.header.timestamp = value;
    const overlay = new TrafiklabSwedenRealtimeOverlay("key", "https://trafiklab.test", async () => response(feed),
      () => new Date(feedTime * 1_000), ["sl"]);
    expect(await overlay.platformUpdates(trip())).toEqual([]);
  });

  it.each([feedTime - 301, feedTime + 121])("rejects a stale or future trip observation under a fresh header (%s)", async (value) => {
    const feed = tripFeed(); feed.entity![0]!.tripUpdate!.timestamp = value;
    const overlay = new TrafiklabSwedenRealtimeOverlay("key", "https://trafiklab.test", async () => response(feed),
      () => new Date(feedTime * 1_000), ["sl"]);
    expect(await overlay.platformUpdates(trip())).toEqual([]);
  });

  it("rechecks publisher freshness when a matched trip is reused from cache", async () => {
    let now = feedTime * 1_000;
    const feed = tripFeed(); feed.entity![0]!.tripUpdate!.timestamp = feedTime - 290;
    let requests = 0;
    const overlay = new TrafiklabSwedenRealtimeOverlay("key", "https://trafiklab.test", async () => {
      requests += 1; return response(feed);
    }, () => new Date(now), ["sl"]);
    expect(await overlay.platformUpdates(trip())).toHaveLength(2);
    now += 11_000;
    expect(await overlay.platformUpdates(trip())).toEqual([]);
    expect(requests).toBe(1);
  });

  it("rejects another service date even when its native trip ID is reused", async () => {
    const feed = tripFeed(); feed.entity![0]!.tripUpdate!.trip.startDate = "20260804";
    const overlay = new TrafiklabSwedenRealtimeOverlay("key", "https://trafiklab.test", async () => response(feed),
      () => new Date(feedTime * 1_000), ["sl"]);
    expect(await overlay.platformUpdates(trip())).toEqual([]);
  });

  it("rechecks a cached feed header instead of treating a fresh trip timestamp as a fresh publication", async () => {
    let now = feedTime * 1_000;
    const feed = tripFeed(); feed.header.timestamp = feedTime - 290;
    const overlay = new TrafiklabSwedenRealtimeOverlay("key", "https://trafiklab.test", async () => response(feed),
      () => new Date(now), ["sl"]);
    expect(await overlay.platformUpdates(trip())).toHaveLength(2);
    now += 11_000;
    expect(await overlay.platformUpdates(trip())).toEqual([]);
  });

  it("honors explicit NO_DATA even when an event supplies a delay", async () => {
    const feed = tripFeed();
    for (const update of feed.entity![0]!.tripUpdate!.stopTimeUpdate!) {
      update.scheduleRelationship = transit_realtime.TripUpdate.StopTimeUpdate.ScheduleRelationship.NO_DATA;
    }
    const overlay = new TrafiklabSwedenRealtimeOverlay("key", "https://trafiklab.test", async () => response(feed),
      () => new Date(feedTime * 1_000), ["sl"]);
    expect(await overlay.platformUpdates(trip())).toEqual([]);
  });
});
