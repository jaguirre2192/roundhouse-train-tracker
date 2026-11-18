import { readFileSync } from "node:fs";
import { afterEach, describe, expect, it, vi } from "vitest";
import { denmarkRegionalWatchdogURL, wakeDenmarkRegionalConsumer } from "../src/cloudflare/denmark-realtime-watchdog.js";

const secret = "fixture-watchdog-secret-more-than32-characters";
afterEach(() => { vi.unstubAllGlobals(); vi.useRealTimers(); });

describe("one shared Denmark scheduled watchdog", () => {
  it("leaves credentials, periodic work, and remote watchdogs disabled in the public template", () => {
    const primary = JSON.parse(readFileSync(new URL("../wrangler.denmark-realtime.jsonc", import.meta.url), "utf8"));
    const regional = JSON.parse(readFileSync(new URL("../wrangler.denmark-regional-realtime.jsonc", import.meta.url), "utf8"));
    expect(primary.vars?.DENMARK_REGIONAL_WATCHDOG_URL).toBeUndefined();
    expect(primary.triggers?.crons ?? []).toEqual([]);
    expect(regional.vars ?? {}).not.toHaveProperty("DENMARK_REGIONAL_WATCHDOG_URL");
    expect(regional.triggers?.crons ?? []).toEqual([]);
  });

  it.each([undefined, "https://evil.test/refresh", `${denmarkRegionalWatchdogURL}?redirect=evil`, `${denmarkRegionalWatchdogURL}/`])("never sends the secret to an absent or drifting destination", async destination => {
    const fetcher = vi.fn(); vi.stubGlobal("fetch", fetcher);
    await wakeDenmarkRegionalConsumer({ RAIL_DATA_REFRESH_SECRET: secret,
      ...(destination === undefined ? {} : { DENMARK_REGIONAL_WATCHDOG_URL: destination }) });
    expect(fetcher).not.toHaveBeenCalled();
  });

  it.each(["redirect", "network", "malformed"])("contains a %s failure without exposing provider body or credentials", async kind => {
    vi.stubGlobal("fetch", vi.fn(async () => {
      if (kind === "network") throw new Error("https://private.test?secret=private-value");
      return kind === "redirect" ? new Response("private-value", { status: 302, headers: { location: "https://evil.test" } })
        : Response.json({ accepted: false, wakeScheduled: false });
    }));
    const result = await wakeDenmarkRegionalConsumer({ RAIL_DATA_REFRESH_SECRET: secret, DENMARK_REGIONAL_WATCHDOG_URL: denmarkRegionalWatchdogURL });
    expect(result.outcome).toBe("failed"); expect(JSON.stringify(result)).not.toMatch(/private|https|secret/u);
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("ends a nonresponsive watchdog call within3seconds even if transport ignores abort", async () => {
    vi.useFakeTimers(); vi.stubGlobal("fetch", vi.fn(async () => new Promise<Response>(() => {})));
    const result = wakeDenmarkRegionalConsumer({ RAIL_DATA_REFRESH_SECRET: secret, DENMARK_REGIONAL_WATCHDOG_URL: denmarkRegionalWatchdogURL });
    await vi.advanceTimersByTimeAsync(3_000);
    expect(await result).toMatchObject({ outcome: "failed", failure: "deadline", httpStatus: null });
  });
});
