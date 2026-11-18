import { afterEach, describe, expect, it, vi } from "vitest";
import { configuredMotis } from "../src/providers/configured-motis.js";

describe("MOTIS backend selection", () => {
  afterEach(() => vi.unstubAllGlobals());

  it.each([
    [undefined, "https://api.transitous.org"],
    ["https://rail-planner.example/", "https://rail-planner.example"],
  ])("uses one origin for trip discovery and journey planning", async (setting, expectedOrigin) => {
    const requests: URL[] = [];
    vi.stubGlobal("fetch", async (input: URL | string, init?: RequestInit) => {
      requests.push(new URL(input));
      expect(new Headers(init?.headers).get("user-agent")).toMatch(/^Roundhouse\/[\d.]+ \(\+https:\/\/gettraintracker\.com\/support\)$/u);
      return Response.json([]);
    });
    const motis = configuredMotis(setting);
    await motis.discovery.searchStations("Berlin");
    const beforePlanning = requests.length;
    await motis.journeys.searchPlaces("Berlin", 5);
    expect(beforePlanning).toBeGreaterThan(0);
    expect(requests.length).toBeGreaterThan(beforePlanning);
    expect([...new Set(requests.map(url => url.origin))]).toEqual([expectedOrigin]);
  });

  it("rejects an incompatible planner path instead of quietly sending searches elsewhere", () => {
    expect(() => configuredMotis("https://rail-planner.example/other/api")).toThrow("MOTIS_BASE_URL");
  });
});
