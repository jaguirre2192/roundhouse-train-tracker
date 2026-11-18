import { describe, expect, it, vi } from "vitest";
import { MalaysiaVehiclePositionOverlay } from "../src/providers/malaysia-vehicle-position.js";
import type { MalaysiaVehicleFeedOptions } from "../src/providers/malaysia-vehicle-feed.js";
import { response, snapshot } from "./helpers/malaysia-vehicle-position.js";

const baseTime = Date.parse("2026-07-21T12:55:30Z");
function overlay(fetcher: typeof fetch, options: MalaysiaVehicleFeedOptions, now = () => baseTime) {
  return new MalaysiaVehiclePositionOverlay("https://example.test/retry-persistence.pb", fetcher, () => new Date(now()), options);
}

describe("Malaysia persisted Retry-After", () => {
  it.each(["90", "Tue, 21 Jul 2026 12:57:00 GMT"])("retains Retry-After %s through owner recreation", async (retryAfter) => {
    let now = baseTime, blockedUntil = 0, lastReservedAt = 0, calls = 0;
    const options: MalaysiaVehicleFeedOptions = {
      reserveRequest: async () => {
        if (now < blockedUntil || now - lastReservedAt < 30_000) return false;
        lastReservedAt = now; return true;
      },
      deferRequestUntil: async (until) => { blockedUntil = Math.max(blockedUntil, until); },
    };
    const fetcher: typeof fetch = async () => {
      calls += 1;
      return calls === 1 ? new Response(null, { status: 429, headers: { "retry-after": retryAfter } }) : response();
    };
    const create = () => overlay(fetcher, options, () => now);
    await expect(create().positionUpdates(snapshot())).rejects.toThrow("429");
    expect(blockedUntil).toBe(baseTime + 90_000);
    now += 30_000;
    expect(await create().positionUpdates(snapshot())).toEqual([]);
    now += 59_999;
    expect(await create().positionUpdates(snapshot())).toEqual([]);
    expect(calls).toBe(1);
    now += 1;
    expect(await create().positionUpdates(snapshot())).toHaveLength(1);
    expect(calls).toBe(2);
  });

  it("awaits the persistent cooldown before completing the failed request", async () => {
    let complete!: () => void;
    const deferRequestUntil = vi.fn(async () => new Promise<void>(resolve => { complete = resolve; }));
    const request = overlay(async () => new Response(null, { status: 429, headers: { "retry-after": "90" } }),
      { deferRequestUntil }).positionUpdates(snapshot());
    let settled = false;
    const outcome = request.then(() => { settled = true; }, () => { settled = true; });
    await vi.waitFor(() => expect(deferRequestUntil).toHaveBeenCalledWith(baseTime + 90_000));
    expect(settled).toBe(false);
    complete();
    await outcome;
    await expect(request).rejects.toThrow("429");
  });

  it("fails closed if persistence fails, even when older cached points are available", async () => {
    const bytes = new Uint8Array(await response().arrayBuffer());
    const fetcher = vi.fn<typeof fetch>(async () => new Response(null, { status: 503, headers: { "retry-after": "90" } }));
    const value = overlay(fetcher, {
      readFeed: async () => ({ fetchedAt: baseTime - 30_000, bytes }), reserveRequest: async () => true,
      deferRequestUntil: async () => { throw new Error("private storage detail"); },
    });
    await expect(value.positionUpdates(snapshot())).rejects.toThrow("Malaysia GTFS-RT cooldown persistence failed");
    await expect(value.positionUpdates(snapshot())).rejects.toThrow("Malaysia GTFS-RT cooldown persistence failed");
    expect(fetcher).toHaveBeenCalledTimes(1);
  });

  it.each([null, "invalid", "-1", "10", "0", "Tue, 21 Jul 2026 12:55:00 GMT"])(
    "does not persist Retry-After %s when it cannot extend the existing minimum cooldown", async (retryAfter) => {
      const deferRequestUntil = vi.fn<(until: number) => Promise<void>>();
      const headers = retryAfter === null ? undefined : { "retry-after": retryAfter };
      const value = overlay(async () => new Response(null, { status: 429, ...(headers === undefined ? {} : { headers }) }),
        { deferRequestUntil });
      await expect(value.positionUpdates(snapshot())).rejects.toThrow("429");
      expect(deferRequestUntil).not.toHaveBeenCalled();
    },
  );
});
