import { describe, expect, it, vi } from "vitest";
import { SrbijaVozAPI } from "../src/providers/srbijavoz-api.js";
import { RailProviderUnavailableError } from "../src/providers/rail-provider-error.js";

describe("Srbijavoz API request boundaries", () => {
  it("coalesces the same route/date and retains the observation time for the 30-second cache", async () => {
    let now = new Date("2026-11-13T09:00:00Z");
    const fetcher = vi.fn<typeof fetch>(async () => Response.json([]));
    const api = new SrbijaVozAPI(fetcher, () => now);
    const first = await Promise.all([api.connections(16052, 16807, "2026-11-13"), api.connections(16052, 16807, "2026-11-13")]);
    expect(fetcher).toHaveBeenCalledTimes(1);
    now = new Date("2026-11-13T09:00:29Z");
    expect((await api.connections(16052, 16807, "2026-11-13")).fetchedAt).toBe(first[0]!.fetchedAt);
    now = new Date("2026-11-13T09:00:31Z");
    expect((await api.connections(16052, 16807, "2026-11-13")).fetchedAt).toBe(now.toISOString());
    expect(fetcher).toHaveBeenCalledTimes(2);
  });

  it.each([403, 429])("does not retry %s and honors Retry-After across route keys", async (status) => {
    let now = new Date("2026-11-13T09:00:00Z");
    const fetcher = vi.fn<typeof fetch>(async () => new Response("limited", { status, headers: { "retry-after": "120" } }));
    const api = new SrbijaVozAPI(fetcher, () => now);
    await expect(api.connections(16052, 16807, "2026-11-13")).rejects.toBeInstanceOf(RailProviderUnavailableError);
    now = new Date("2026-11-13T09:01:59Z");
    await expect(api.connections(16807, 16052, "2026-11-14")).rejects.toBeInstanceOf(RailProviderUnavailableError);
    expect(fetcher).toHaveBeenCalledTimes(1);
    now = new Date("2026-11-13T09:02:00Z");
    await expect(api.connections(16052, 16807, "2026-11-13")).rejects.toBeInstanceOf(RailProviderUnavailableError);
    expect(fetcher).toHaveBeenCalledTimes(2);
  });

  it("rejects unverified stations and invalid calendar dates before requesting data", async () => {
    const fetcher = vi.fn<typeof fetch>();
    const api = new SrbijaVozAPI(fetcher);
    await expect(api.connections(16052, 24402, "2026-11-13")).rejects.toBeInstanceOf(RailProviderUnavailableError);
    await expect(api.connections(16052, 16807, "2026-02-30")).rejects.toBeInstanceOf(RailProviderUnavailableError);
    expect(fetcher).not.toHaveBeenCalled();
  });

  it("fails closed when an HTTP 200 is not a public timetable array", async () => {
    const api = new SrbijaVozAPI(async () => Response.json({ error: "not a timetable" }));
    await expect(api.connections(16052, 16807, "2026-11-13")).rejects.toBeInstanceOf(RailProviderUnavailableError);
  });
});
