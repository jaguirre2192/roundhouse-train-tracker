import { syntheticChepeSchedule } from "./fixtures/chepe-sample.js";
import { describe, expect, it } from "vitest";
import type { WatcherRepository } from "../src/db/repository.js";
import { makeApp } from "../src/http/app.js";
import { ChepeProvider } from "../src/providers/chepe.js";
import { ProviderRegistry } from "../src/providers/provider.js";
import { providerRetryAfter, RailProviderUnavailableError } from "../src/providers/rail-provider-error.js";

const board = "/v1/stations/board?stationId=mx:chepe:los-mochis&source=chepe&nativeId=los-mochis&at=2026-11-14T13:00:00Z&direction=departures";
const trip = "/v1/trips/snapshot?id=mx:chepe:express-los-mochis-creel:2026-11-14&source=chepe&nativeId=express-los-mochis-creel:2026-11-14&serviceDate=2026-11-14";

describe("rail provider unavailable HTTP contract", () => {
  it.each([board, trip])("returns a retryable sanitized failure for %s", async url => {
    const provider = new ChepeProvider(async () => new Response("Request Rejected opaque-private-reference"), undefined, syntheticChepeSchedule);
    const app = makeApp({} as WatcherRepository, new ProviderRegistry([provider]), "silent");
    try {
      const response = await app.inject({ method: "GET", url });
      expect(response.statusCode).toBe(503);
      expect(response.json()).toEqual({ error: "provider_unavailable" });
      expect(response.headers["retry-after"]).toBe("60");
      expect(response.headers["cache-control"]).toBe("no-store");
      expect(response.body).not.toContain("opaque-private-reference");
    } finally { await app.close(); }
  });

  it("bounds retry delays and tolerates RPC losing custom properties", () => {
    expect(providerRetryAfter(new RailProviderUnavailableError("outage", Number.NaN))).toBe(60);
    expect(providerRetryAfter(new RailProviderUnavailableError("outage", 900))).toBe(300);
    expect(providerRetryAfter(new RailProviderUnavailableError("outage", -5))).toBe(1);
    expect(providerRetryAfter(new Error("remote outage"))).toBe(60);
  });
});
