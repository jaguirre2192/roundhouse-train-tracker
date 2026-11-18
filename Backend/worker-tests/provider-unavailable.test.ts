import { SELF } from "cloudflare:test";
import { describe, expect, it, vi } from "vitest";

describe("rail provider outage through Worker RPC", () => {
  it("returns 503 and backs off Chepe rejection instead of repeatedly failing 500", async () => {
    const externalFetch = vi.spyOn(globalThis, "fetch").mockImplementation(async input => {
      const url = new URL(typeof input === "string" || input instanceof URL ? input : input.url);
      if (url.origin !== "https://chepe.mx") throw new Error("Unexpected upstream");
      return new Response("<title>Request Rejected</title><p>opaque-reference</p>");
    });
    try {
      const paths = [
        "/v1/stations/board?stationId=mx:chepe:los-mochis&source=chepe&nativeId=los-mochis&at=2026-11-14T13:00:00Z&direction=departures",
        "/v1/trips/snapshot?id=mx:chepe:express-los-mochis-creel:2026-11-14&source=chepe&nativeId=express-los-mochis-creel:2026-11-14&serviceDate=2026-11-14",
      ];
      for (const path of paths) {
        const response = await SELF.fetch("https://example.test" + path);
        expect(response.status).toBe(503);
        expect(response.headers.get("retry-after")).toBe("60");
        expect(response.headers.get("cache-control")).toBe("no-store");
        await expect(response.json()).resolves.toEqual({ error: "provider_unavailable" });
      }
      expect(externalFetch).toHaveBeenCalledTimes(1);
    } finally { externalFetch.mockRestore(); }
  });
});
