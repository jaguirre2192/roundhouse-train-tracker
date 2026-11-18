import { createExecutionContext, env, runInDurableObject, waitOnExecutionContext } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker, { type RailMaintenanceEnv } from "../src/cloudflare/rail-maintenance-worker.js";
import { regionalStaticFixture } from "../worker-tests/fixtures/trafiklab-regional-static.js";

const bindings = env as unknown as RailMaintenanceEnv;
const secret = "rail-maintenance-test-secret-32-characters";
type IncomingRequest = Parameters<typeof worker.fetch>[0];
function request(path: string, method = "GET", authorization = `Bearer ${secret}`): IncomingRequest {
  return new Request(`https://maintenance.test${path}`, { method, headers: { authorization } }) as IncomingRequest;
}
function send(path: string, method = "GET", authorization?: string) {
  return worker.fetch(request(path, method, authorization), bindings);
}

beforeEach(async () => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(new Date("2026-11-13T09:00:00Z"));
  vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("Unexpected outbound request in test"); }));
  await runInDurableObject(bindings.RAIL_MAINTENANCE.getByName("global"), async (_instance, state) => state.storage.deleteAll());
});
afterEach(() => { vi.unstubAllGlobals(); vi.useRealTimers(); });

describe("isolated rail maintenance Worker", () => {
  it("requires the scoped secret for health and refresh and rejects other methods", async () => {
    expect((await send("/health", "GET", "")).status).toBe(401);
    expect((await send("/refresh", "POST", "Bearer wrong")).status).toBe(401);
    expect((await send("/health", "GET", "x".repeat(513))).status).toBe(401);
    expect((await send("/refresh", "GET")).status).toBe(405);
    expect((await send("/health", "POST")).status).toBe(405);
    const health = await send("/health");
    expect(health.status).toBe(200);
    expect(await health.json()).toMatchObject({ configured: true, maintenance: { outcome: "not-attempted" } });
    expect(fetch).not.toHaveBeenCalled();
  });

  it("fails closed when either secret is absent and scheduled work does not start", async () => {
    expect((await worker.fetch(request("/health"), { ...bindings, RAIL_DATA_REFRESH_SECRET: "" })).status).toBe(503);
    const incomplete = { ...bindings, TRAFIKLAB_GTFS_REGIONAL_STATIC_API_KEY: "" };
    expect((await worker.fetch(request("/refresh", "POST"), incomplete)).status).toBe(503);
    const ctx = createExecutionContext();
    await worker.scheduled({} as ScheduledController, incomplete, ctx);
    await waitOnExecutionContext(ctx);
    expect(fetch).not.toHaveBeenCalled();
  });

  it("compiles once, publishes only the compact index, and persists safe status", async () => {
    vi.mocked(fetch).mockImplementation(async (input, init) => {
      const url = new URL(String(input));
      // Native workerd Request validation must run even though network I/O is stubbed.
      // Unsupported redirect modes otherwise disappear behind the mocked fetch.
      const native = new Request(String(input), init);
      expect(native.redirect).toBe("manual");
      expect(new Headers(init?.headers).get("user-agent")).toBe("TrainTrackerMaintenance/1.0");
      expect(init?.signal).toBeInstanceOf(AbortSignal);
      expect(init?.redirect).toBe("manual");
      if (url.hostname === "opendata.samtrafiken.se") {
        expect(url.pathname).toBe("/gtfs/skane/skane.zip");
        expect(url.searchParams.get("key")).toBe("rail-maintenance-static-test-key");
        return new Response(regionalStaticFixture());
      }
      expect(url.href).toBe("https://roundhouse-api.example.invalid/internal/rail-data/trafiklab-skane");
      expect(init?.method).toBe("POST");
      expect(new Headers(init?.headers).get("authorization")).toBe(`Bearer ${secret}`);
      const body = JSON.parse(init?.body as string);
      expect(body).toMatchObject({ operator: "skane", feedVersion: "2026-11-13" });
      expect(body.trips).toHaveLength(1);
      return Response.json({ outcome: "stored", feedVersion: body.feedVersion });
    });
    const response = await send("/refresh", "POST");
    expect(await response.json()).toMatchObject({ maintenance: { outcome: "stored", tripCount: 1, feedVersion: "2026-11-13",
      diagnostics: { phase: "publish-response", httpStatus: 200, redirectStatus: null,
        downloadBytes: regionalStaticFixture().byteLength, downloadComplete: true } } });
    expect(fetch).toHaveBeenCalledTimes(2);
    vi.setSystemTime(new Date("2026-11-13T09:00:41Z"));
    const repeated = await send("/refresh", "POST");
    expect(await repeated.json()).toMatchObject({ maintenance: { outcome: "stored" } });
    expect(fetch).toHaveBeenCalledTimes(2);
    expect(await (await send("/health")).text()).not.toMatch(/test-key|test-secret|https:\/\//u);
    await runInDurableObject(bindings.RAIL_MAINTENANCE.getByName("global"), async (_instance, state) => {
      expect((await state.storage.list({ prefix: "rail-index:skane:" })).size).toBe(0);
    });
  });

  it("cancels an unsuccessful static response and never publishes or retries", async () => {
    let cancelled = false;
    vi.mocked(fetch).mockResolvedValue(new Response(new ReadableStream({
      cancel() { cancelled = true; },
    }), { status: 503 }));
    expect(await (await send("/refresh", "POST")).json()).toMatchObject({ maintenance: { outcome: "failed",
      diagnostics: { phase: "static-response", httpStatus: 503, redirectStatus: null, downloadBytes: 0, downloadComplete: false } } });
    expect(cancelled).toBe(true);
    await send("/refresh", "POST");
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("records a blocked redirect status without following or retaining its target", async () => {
    vi.mocked(fetch).mockResolvedValue(new Response(null, { status: 302,
      headers: { location: "https://private.test/archive?key=private-signature" } }));
    const text = await (await send("/refresh", "POST")).text();
    expect(JSON.parse(text)).toMatchObject({ maintenance: { outcome: "failed", diagnostics: {
      phase: "static-response", httpStatus: 302, redirectStatus: 302, downloadBytes: 0, downloadComplete: false,
    } } });
    expect(text).not.toMatch(/private|signature|https/u);
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("distinguishes a network failure without persisting its exception text", async () => {
    vi.mocked(fetch).mockRejectedValue(new Error("https://private.test/?key=private-key"));
    const text = await (await send("/refresh", "POST")).text();
    expect(JSON.parse(text)).toMatchObject({ maintenance: { outcome: "failed", diagnostics: {
      phase: "static-request", httpStatus: null, redirectStatus: null, downloadBytes: 0, downloadComplete: false,
    } } });
    expect(text).not.toMatch(/private|https/u);
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it.each(["oversized", "malformed", "wrong-version"])("rejects %s publication acknowledgements", async (kind) => {
    let cancelled = false;
    vi.mocked(fetch).mockImplementation(async input => {
      if (String(input).startsWith("https://opendata.samtrafiken.se/")) return new Response(regionalStaticFixture());
      if (kind === "oversized") return new Response(new ReadableStream<Uint8Array>({
        start(controller) { controller.enqueue(new Uint8Array(2_049).fill(32)); },
        cancel() { cancelled = true; },
      }), { headers: { "content-length": "1" } });
      return new Response(kind === "malformed" ? "{" : JSON.stringify({ outcome: "stored", feedVersion: "2026-11-12" }));
    });
    expect(await (await send("/refresh", "POST")).json()).toMatchObject({ maintenance: { outcome: "failed" } });
    expect(fetch).toHaveBeenCalledTimes(2);
    if (kind === "oversized") expect(cancelled).toBe(true);
  });

  it("never exposes untrusted metadata from a rejected publication", async () => {
    vi.mocked(fetch).mockImplementation(async input => String(input).startsWith("https://opendata.samtrafiken.se/")
      ? new Response(regionalStaticFixture())
      : Response.json({ outcome: "invalid", feedVersion: "https://provider.test/?key=private", error: "private" }, { status: 400 }));
    const response = await send("/refresh", "POST");
    const text = await response.text();
    expect(JSON.parse(text)).toMatchObject({ maintenance: { outcome: "invalid", feedVersion: null } });
    expect(text).not.toMatch(/private|https|provider/u);
  });

  it("authenticates before reading retry bodies and bounds actual streamed bytes", async () => {
    const unauthorized = new Request("https://maintenance.test/refresh", { method: "POST",
      headers: { authorization: "Bearer wrong", "content-type": "application/json" }, body: "x".repeat(300) }) as IncomingRequest;
    expect((await worker.fetch(unauthorized, bindings)).status).toBe(401);
    expect(unauthorized.bodyUsed).toBe(false);
    let cancelled = false;
    const oversized = new Request("https://maintenance.test/refresh", { method: "POST",
      headers: { authorization: `Bearer ${secret}`, "content-type": "application/json", "content-length": "1" },
      body: new ReadableStream<Uint8Array>({ start(controller) { controller.enqueue(new Uint8Array(257)); },
        cancel() { cancelled = true; } }),
    }) as IncomingRequest;
    expect((await worker.fetch(oversized, bindings)).status).toBe(413);
    expect(cancelled).toBe(true);
    expect(fetch).not.toHaveBeenCalled();
  });

  it.each([{}, [], null, { retryFailedAttemptAt: "yesterday" },
    { retryFailedAttemptAt: "2026-11-13T09:00:00.000Z", force: true }])("rejects invalid retry body %j", async body => {
    const input = new Request("https://maintenance.test/refresh", { method: "POST",
      headers: { authorization: `Bearer ${secret}`, "content-type": "application/json" }, body: JSON.stringify(body) }) as IncomingRequest;
    expect((await worker.fetch(input, bindings)).status).toBe(400);
    expect(fetch).not.toHaveBeenCalled();
  });

  it("allows one exact authenticated failure retry and rejects replay while empty POST remains normal", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(new Response(null, { status: 503 }));
    const first = await (await send("/refresh", "POST")).json() as { maintenance: { lastAttemptAt: string } };
    const retry = () => new Request("https://maintenance.test/refresh", { method: "POST",
      headers: { authorization: `Bearer ${secret}`, "content-type": "application/json" },
      body: JSON.stringify({ retryFailedAttemptAt: first.maintenance.lastAttemptAt }) }) as IncomingRequest;
    vi.setSystemTime(new Date("2026-11-13T09:00:01Z"));
    vi.mocked(fetch).mockImplementation(async input => String(input).startsWith("https://opendata.samtrafiken.se/")
      ? new Response(regionalStaticFixture()) : Response.json({ outcome: "stored", feedVersion: "2026-11-13" }));
    const recovered = await worker.fetch(retry(), bindings);
    expect(recovered.status).toBe(200);
    expect(await recovered.json()).toMatchObject({ maintenance: { outcome: "stored", attemptsToday: 2,
      previousAttempt: { outcome: "failed", lastAttemptAt: first.maintenance.lastAttemptAt } } });
    expect((await worker.fetch(retry(), bindings)).status).toBe(409);
    const empty = new Request("https://maintenance.test/refresh", { method: "POST",
      headers: { authorization: `Bearer ${secret}`, "content-type": "application/json", "content-length": "0" }, body: "" }) as IncomingRequest;
    expect(await (await worker.fetch(empty, bindings)).json()).toMatchObject({ maintenance: { attemptsToday: 2, outcome: "stored" } });
    expect(fetch).toHaveBeenCalledTimes(3); // Two static requests in total, one publication.
  });
});
