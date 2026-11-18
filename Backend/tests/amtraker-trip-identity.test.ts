import { describe, expect, it } from "vitest";
import { AmtrakerProvider, type AmtrakerTrain } from "../src/providers/amtraker.js";
import { amtrakerTripForReference } from "../src/providers/amtraker-trip-identity.js";

function train(id: string, times: string[]): AmtrakerTrain {
  return { trainID: id, trainNum: "7", routeName: "Empire Builder", stations: times.map((schDep, index) =>
    ({ code: `S${index}`, name: `Station ${index}`, schDep })) };
}
function match(trains: AmtrakerTrain[], nativeId = "7", serviceDate = "2026-11-13") {
  return amtrakerTripForReference(trains, { id: `us:amtraker:${nativeId}`, source: "amtraker", nativeId, serviceDate });
}

function providerFor(trains: AmtrakerTrain[]): AmtrakerProvider {
  return new AmtrakerProvider("https://example.test", async (input) => {
    const url = new URL(String(input));
    return Response.json(url.pathname === "/stations" ? {
      S0: { code: "S0", name: "Origin", lat: 34.05, lon: -118.24 },
      S1: { code: "S1", name: "Destination", lat: 33.77, lon: -118.19 },
    } : { "7": trains });
  }, () => new Date("2026-11-14T03:00:00Z"));
}

describe("Amtraker service instance identity", () => {
  it("selects the requested UTC boarding day instead of the first same-number train", () => {
    const previous = train("7-12", ["2026-11-12T16:00:00Z"]);
    const current = train("7-13", ["2026-11-13T16:00:00Z"]);
    expect(match([previous, current])).toBe(current);
  });
  it("retains an overnight train when boarding is on the following UTC day", () => {
    const overnight = train("7-12", ["2026-11-12T16:00:00Z", "2026-11-12T22:30:00-08:00"]);
    expect(match([overnight], "7-12")).toBe(overnight);
  });
  it("accepts a saved local boarding day when every scheduled call is on the next UTC day", () => {
    const evening = train("7-13", ["2026-11-13T18:00:00-08:00", "2026-11-13T19:00:00-08:00"]);
    expect(match([evening], "7-13", "2026-11-13")).toBe(evening);
    expect(match([evening], "7-13", "2026-11-14")).toBe(evening);
  });
  it("accepts both local and UTC expected boarding dates after a delay", () => {
    const delayed = train("7-12", ["2026-11-12T23:55:00-08:00"]);
    delayed.stations[0]!.dep = "2026-11-13T18:00:00-08:00";
    expect(match([delayed], "7-12", "2026-11-13")).toBe(delayed);
    expect(match([delayed], "7-12", "2026-11-14")).toBe(delayed);
  });
  it("rejects ambiguous overlapping trains for legacy numeric references", () => {
    expect(match([train("7-12", ["2026-11-13T08:00:00Z"]), train("7-13", ["2026-11-13T16:00:00Z"])])).toBeNull();
  });
  it("does not apply exact-instance calendar tolerance to a numeric train lookup", () => {
    const previous = train("7-12", ["2026-11-12T16:00:00-05:00"]);
    const current = train("7-13", ["2026-11-13T16:00:00-05:00"]);
    expect(match([previous])).toBeNull();
    expect(match([previous, current])).toBe(current);
  });
  it("limits an exact instance's calendar tolerance to one day", () => {
    const current = train("7-13", ["2026-11-13T16:00:00-05:00"]);
    expect(match([current], "7-13", "2026-11-12")).toBe(current);
    expect(match([current], "7-13", "2026-11-14")).toBe(current);
    expect(match([current], "7-13", "2026-11-15")).toBeNull();
  });
  it("preserves an exact instance when another same-number train overlaps", () => {
    const exact = train("7-12", ["2026-11-13T08:00:00Z"]);
    expect(match([exact, train("7-13", ["2026-11-13T16:00:00Z"])], "7-12")).toBe(exact);
  });
  it("rejects reused day-of-month IDs from a different month", () => {
    expect(match([train("7-13", ["2026-10-13T16:00:00Z"])], "7-13")).toBeNull();
  });
  it("does not use malformed or missing schedule dates as identity evidence", () => {
    expect(match([train("7-13", ["invalid"])], "7-13")).toBeNull();
    expect(match([train("7-13", [])], "7-13")).toBeNull();
  });

  it("resolves a West Coast evening board reference without shifting its saved local day", async () => {
    const evening = train("7-13", ["2026-11-13T18:00:00-08:00", "2026-11-13T19:00:00-08:00"]);
    const provider = providerFor([evening]);
    const board = await provider.fetchBoard({
      stationId: "us:amtraker:S0", source: "amtraker", nativeId: "S0",
      at: "2026-11-14T01:50:00Z", direction: "departures",
    });
    expect(board).toHaveLength(1);
    expect(board[0]!.trip.serviceDate).toBe("2026-11-13");
    const snapshot = await provider.fetchTrip(board[0]!.trip);
    expect(snapshot.id).toBe("us:amtraker:7-13");
    expect(snapshot.serviceDate).toBe("2026-11-13");
    expect(snapshot.stops[0]!.scheduledDeparture).toBe("2026-11-13T18:00:00-08:00");
  });

  it("resolves a board reference whose delayed departure crossed midnight", async () => {
    const delayed = train("7-13", ["2026-11-13T23:40:00Z", "2026-11-13T23:55:00Z"]);
    delayed.stations[0]!.dep = "2026-11-14T00:10:00Z";
    delayed.stations[1]!.dep = "2026-11-14T00:25:00Z";
    const provider = providerFor([delayed]);
    const board = await provider.fetchBoard({
      stationId: "us:amtraker:S0", source: "amtraker", nativeId: "S0",
      at: "2026-11-14T00:00:00Z", direction: "departures",
    });
    expect(board).toHaveLength(1);
    expect(board[0]!.trip.serviceDate).toBe("2026-11-14");
    const snapshot = await provider.fetchTrip(board[0]!.trip);
    expect(snapshot.id).toBe("us:amtraker:7-13");
    expect(snapshot.serviceDate).toBe("2026-11-14");
    expect(snapshot.stops[0]!.expectedDeparture).toBe("2026-11-14T00:10:00Z");
  });

  it("returns an exact saved instance for a legacy numeric lookup", async () => {
    const provider = providerFor([train("7-13", ["2026-11-13T16:00:00Z"])]);
    const snapshot = await provider.fetchTrip({
      id: "us:amtraker:7", source: "amtraker", nativeId: "7", serviceDate: "2026-11-13",
    });
    expect(snapshot.id).toBe("us:amtraker:7-13");
    expect(snapshot.nativeId).toBe("7-13");
  });

  it("refreshes a saved delayed boarding day after the same exact train's delay is corrected", async () => {
    const delayed = train("7-13", ["2026-11-13T16:00:00-05:00", "2026-11-13T17:00:00-05:00"]);
    delayed.stations[0]!.dep = "2026-11-14T00:10:00-05:00";
    delayed.stations[1]!.dep = "2026-11-14T01:10:00-05:00";
    const provider = providerFor([delayed]);
    const board = await provider.fetchBoard({
      stationId: "us:amtraker:S0", source: "amtraker", nativeId: "S0",
      at: "2026-11-13T20:00:00Z", direction: "departures",
    });
    expect(board).toHaveLength(1);
    const saved = board[0]!.trip;
    expect(saved.serviceDate).toBe("2026-11-14");
    expect((await provider.fetchTrip(saved)).stops[0]!.expectedDeparture).toBe("2026-11-14T00:10:00-05:00");

    delayed.stations[0]!.dep = "2026-11-13T16:30:00-05:00";
    delayed.stations[1]!.dep = "2026-11-13T17:30:00-05:00";
    const refreshed = await provider.fetchTrip(saved);

    expect(refreshed.id).toBe(saved.id);
    expect(refreshed.serviceDate).toBe(saved.serviceDate);
    expect(refreshed.stops[0]!.expectedDeparture).toBe("2026-11-13T16:30:00-05:00");
  });
});
