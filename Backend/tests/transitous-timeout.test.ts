import { afterEach, describe, expect, it, vi } from "vitest";
import { TransitousJourneyProvider } from "../src/providers/transitous-journeys.js";
import { TransitousProvider } from "../src/providers/transitous.js";
import { encodeRailPlaceId } from "../src/providers/rail-place-id.js";

const baseUrl = "https://example.test";

function stationId(nativeId: string, countryCode: string): string {
  return encodeRailPlaceId({
    provider: "transitous", kind: "station", nativeId, countryCode,
    latitude: null, longitude: null,
  });
}

function controlledTimeouts() {
  vi.useFakeTimers();
  return vi.spyOn(AbortSignal, "timeout").mockImplementation((milliseconds) => {
    const controller = new AbortController();
    setTimeout(() => controller.abort(new DOMException("upstream deadline", "TimeoutError")), milliseconds);
    return controller.signal;
  });
}

afterEach(() => {
  vi.restoreAllMocks();
  vi.useRealTimers();
});

const requests: [string, (fetcher: typeof fetch) => Promise<unknown>][] = [
  ["station geocode", (fetcher) => new TransitousProvider(baseUrl, fetcher).searchStations("Berlin")],
  ["board", (fetcher) => new TransitousProvider(baseUrl, fetcher).fetchBoard({
    stationId: "eu:transitous:de-berlin", source: "transitous", nativeId: "de-berlin",
    at: "2026-07-24T08:00:00Z", direction: "departures",
  })],
  ["trip", (fetcher) => new TransitousProvider(baseUrl, fetcher).fetchTrip({
    id: "eu:transitous:de-ice", source: "transitous", nativeId: "de-ice", serviceDate: "2026-07-24",
  })],
  ["place geocode", (fetcher) => new TransitousJourneyProvider(baseUrl, fetcher).searchPlaces("Berlin", 5)],
  ["journey plan", (fetcher) => new TransitousJourneyProvider(baseUrl, fetcher).searchJourneys({
    originId: stationId("fr-eurostar_paris_nord", "FR"),
    destinationId: stationId("nl-openov_amsterdam_centraal", "NL"),
    time: "2026-07-24T08:00:00+02:00", arriveBy: false, maxTransfers: 4, providerCursor: null,
  })],
];

describe("Transitous request deadlines", () => {
  it.each(requests)("bounds %s to twenty seconds without retrying", async (_name, request) => {
    const timeout = controlledTimeouts();
    const fetcher = vi.fn<typeof fetch>(async (_input, init) => new Promise<Response>((_resolve, reject) => {
      init!.signal!.addEventListener("abort", () => reject(init!.signal!.reason), { once: true });
    }));
    const pending = request(fetcher);
    let settled = false;
    void pending.then(() => { settled = true; }, () => { settled = true; });

    await vi.advanceTimersByTimeAsync(19_999);
    expect(settled).toBe(false);
    await vi.advanceTimersByTimeAsync(1);

    await expect(pending).rejects.toThrow(/deadline|timed out/u);
    expect(timeout).toHaveBeenCalledExactlyOnceWith(20_000);
    expect(fetcher).toHaveBeenCalledTimes(1);
  });

  it("accepts valid geocode data arriving after sixteen seconds", async () => {
    controlledTimeouts();
    const fetcher = vi.fn<typeof fetch>(async (_input, init) => new Promise<Response>((resolve, reject) => {
      setTimeout(() => resolve(Response.json([{
        type: "STOP", name: "Berlin Hbf", id: "de-test-berlin-hbf",
        lat: 52.525, lon: 13.369, country: "DE", tz: "Europe/Berlin", modes: ["LONG_DISTANCE"],
      }])), 16_690);
      init!.signal!.addEventListener("abort", () => reject(init!.signal!.reason), { once: true });
    }));
    const pending = new TransitousJourneyProvider(baseUrl, fetcher).searchPlaces("Berlin", 5);

    await vi.advanceTimersByTimeAsync(16_690);

    expect((await pending).map((place) => place.displayName)).toEqual(["Berlin Hbf"]);
    expect(fetcher).toHaveBeenCalledTimes(1);
  });

  it("classifies an abort while reading a successful response body as a timeout", async () => {
    controlledTimeouts();
    let readingBody = false;
    const fetcher = vi.fn<typeof fetch>(async (_input, init) => {
      const response = Response.json([]);
      vi.spyOn(response, "json").mockImplementation(async () => new Promise((_resolve, reject) => {
        readingBody = true;
        // Some transports surface a body abort as a generic read error.
        init!.signal!.addEventListener("abort", () => reject(new TypeError("private read diagnostics")), { once: true });
      }));
      return response;
    });
    const pending = new TransitousJourneyProvider(baseUrl, fetcher).searchPlaces("Berlin", 5);
    const failure = expect(pending).rejects.toThrow(/^Transitous request timed out$/u);

    await vi.advanceTimersByTimeAsync(19_999);
    expect(readingBody).toBe(true);
    await vi.advanceTimersByTimeAsync(1);

    await failure;
    expect(fetcher).toHaveBeenCalledTimes(1);
  });

  it("keeps malformed JSON distinct from a timeout", async () => {
    controlledTimeouts();
    const provider = new TransitousJourneyProvider(baseUrl, async () => new Response("not JSON"));

    await expect(provider.searchPlaces("Berlin", 5)).rejects.toThrow(/^Transitous returned an invalid response$/u);
  });
});
