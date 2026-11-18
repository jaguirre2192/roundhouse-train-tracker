import { describe, expect, it, vi } from "vitest";
import { ChepeProvider } from "../src/providers/chepe.js";
import { RailProviderUnavailableError } from "../src/providers/rail-provider-error.js";

import { syntheticChepePublication as publication, syntheticChepeSchedule } from "./fixtures/chepe-sample.js";
const reference = {
  id: "mx:chepe:express-los-mochis-creel:2026-11-14", source: "chepe" as const,
  nativeId: "express-los-mochis-creel:2026-11-14", serviceDate: "2026-11-14",
};
const board = { stationId: "mx:chepe:los-mochis", source: "chepe" as const,
  nativeId: "los-mochis", at: "2026-11-14T13:00:00Z", direction: "departures" as const };

describe("Chepe publication recovery", () => {
  it("classifies HTTP-200 rejection HTML as unavailable and suppresses repeated upstream requests", async () => {
    let now = Date.parse("2026-11-13T09:00:00Z");
    const fetcher = vi.fn(async () => new Response("<title>Request Rejected</title>"));
    const provider = new ChepeProvider(fetcher, () => new Date(now), syntheticChepeSchedule);
    await expect(provider.fetchBoard(board)).rejects.toBeInstanceOf(RailProviderUnavailableError);
    now += 10_000;
    await expect(provider.fetchTrip(reference)).rejects.toMatchObject({ retryAfterSeconds: 50 });
    expect(fetcher).toHaveBeenCalledTimes(1);
    now += 50_001;
    fetcher.mockImplementation(async () => new Response(publication));
    const trip = await provider.fetchTrip(reference);
    expect(trip.stops).toHaveLength(3);
    expect(trip.stops.every(stop => stop.expectedArrival === null && stop.expectedDeparture === null)).toBe(true);
    expect(fetcher).toHaveBeenCalledTimes(2);
  });

  it("rejects a signature with no visible text", async () => {
    const config = JSON.stringify({ ...JSON.parse(syntheticChepeSchedule), publicationSignatures: ["<br>"] });
    const provider = new ChepeProvider(async () => new Response(publication), undefined, config);
    await expect(provider.fetchTrip(reference)).rejects.toBeInstanceOf(RailProviderUnavailableError);
  });

  it("coalesces concurrent board and snapshot verification", async () => {
    let finish!: (response: Response) => void;
    const fetcher = vi.fn(() => new Promise<Response>(resolve => { finish = resolve; }));
    const provider = new ChepeProvider(fetcher, () => new Date("2026-11-13T09:00:00Z"), syntheticChepeSchedule);
    const first = provider.fetchBoard(board);
    const second = provider.fetchTrip(reference);
    expect(fetcher).toHaveBeenCalledTimes(1);
    finish(new Response(publication));
    await expect(first).resolves.toHaveLength(1);
    await expect(second).resolves.toMatchObject({ source: "chepe" });
  });

  it.each([
    ["HTTP error", async () => new Response("unavailable", { status: 503 })],
    ["network failure", async () => { throw new Error("network failure"); }],
    ["unverified publication", async () => new Response("replacement timetable")],
  ])("keeps %s unavailable rather than returning an empty board", async (_name, fetcher) => {
    const provider = new ChepeProvider(fetcher, () => new Date("2026-11-13T09:00:00Z"), syntheticChepeSchedule);
    await expect(provider.fetchBoard(board)).rejects.toBeInstanceOf(RailProviderUnavailableError);
  });

  it("does not serve a previously verified schedule after its verification expires", async () => {
    let now = Date.parse("2026-11-13T09:00:00Z");
    const fetcher = vi.fn(async () => new Response(publication));
    const provider = new ChepeProvider(fetcher, () => new Date(now), syntheticChepeSchedule);
    await provider.fetchTrip(reference);
    now += 6 * 60 * 60_000;
    fetcher.mockImplementation(async () => new Response("Request Rejected"));
    await expect(provider.fetchTrip(reference)).rejects.toBeInstanceOf(RailProviderUnavailableError);
    expect(fetcher).toHaveBeenCalledTimes(2);
  });
});
