import { createExecutionContext, env, runDurableObjectAlarm, runInDurableObject, waitOnExecutionContext } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker, { DenmarkRealtime, type DenmarkRealtimeEnv } from "../src/cloudflare/denmark-realtime-worker.js";
import { denmarkRegionalWatchdogURL, denmarkWatchdogHeader } from "../src/cloudflare/denmark-realtime-watchdog.js";

const bindings = env as unknown as DenmarkRealtimeEnv;
const secret = "denmark-maintenance-test-secret-32-characters";
// Workerd's alarm scheduler uses its real clock even while JS Date is faked.
// Keep fixture alarms in the future; only runDurableObjectAlarm should fire them.
const at = Date.now() + 86_400_000;
const base = "https://sb-duvproddistribution.servicebus.windows.net/rail-main/subscriptions/test-main-office";
const lock = (id: number) => `${base}/messages/${id}/opaque-private-lock-${id}`;
type Incoming = Parameters<typeof worker.fetch>[0];
function request(path: string, method = "GET", authorization = `Bearer ${secret}`, body?: string): Incoming {
  return new Request(`https://consumer.test${path}`, { method, headers: { authorization }, ...(body === undefined ? {} : { body }) }) as Incoming;
}
const send = (path: string, method = "GET") => worker.fetch(request(path, method), bindings);
const stub = () => bindings.DENMARK_REALTIME.getByName("global");
const health = async () => (await send("/health")).json();
async function drain() {
  expect(await (await send("/refresh", "POST")).json()).toEqual({ accepted: true, wakeScheduled: true });
  expect(await runDurableObjectAlarm(stub())).toBe(true);
  return health();
}

beforeEach(async () => {
  vi.useFakeTimers({ toFake: ["Date"] }); vi.setSystemTime(at);
  vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("Unexpected outbound request"); }));
  await runInDurableObject(bindings.DENMARK_REALTIME.getByName("global"), async (instance, state) => {
    await state.storage.deleteAlarm();
    await state.storage.deleteAll();
    Reflect.set(instance, "maintenance", Reflect.get(new DenmarkRealtime(state, bindings), "maintenance"));
  });
});
afterEach(() => { vi.unstubAllGlobals(); vi.useRealTimers(); });

function transport(failure: "none" | "oauth" | "publish" | "complete" | "network" | "backlog" = "none") {
  const calls: string[] = []; let receives = 0;
  vi.mocked(fetch).mockImplementation(async (input, init) => {
    const url = new URL(String(input));
    // Exercise actual Workerd Request validation, including supported redirect
    // mode, rather than allowing a mocked fetch to hide runtime errors.
    expect(new Request(String(input), init).redirect).toBe("manual");
    expect(init?.signal).toBeInstanceOf(AbortSignal);
    if (failure === "network") throw new Error("https://private.test/?key=private-credential");
    if (url.hostname === "login.microsoftonline.com") {
      calls.push("oauth");
      return failure === "oauth" ? new Response("private-credential", { status: 401 })
        : Response.json({ token_type: "Bearer", access_token: "private-fixture-token", expires_in: 3600 });
    }
    if (url.hostname === "roundhouse-api.example.invalid") {
      calls.push("publish");
      expect(url.href).toBe("https://roundhouse-api.example.invalid/internal/rail-data/denmark-siri");
      expect(new Headers(init?.headers).get("authorization")).toBe(`Bearer ${secret}`);
      expect(new Headers(init?.headers).get("content-type")).toBe("application/vnd.roundhouse.denmark-siri-batch+json");
      const batch = JSON.parse(new TextDecoder().decode(init?.body as ArrayBuffer)) as { deliveries: string[] };
      expect(batch.deliveries.length).toBeGreaterThan(0);
      expect(batch.deliveries.every(xml => xml === "<Siri>unchanged source XML</Siri>")).toBe(true);
      return Response.json({ accepted: failure !== "publish", source: "denmark-siri", outcome: "stored",
        deliveries: batch.deliveries.length, ignoredStale: 0 });
    }
    expect(new Headers(init?.headers).get("authorization")).toBe("Bearer private-fixture-token");
    if (init?.method === "POST") {
      calls.push("receive"); receives++;
      return receives <= (failure === "backlog" ? 112 : 1) ? new Response("<Siri>unchanged source XML</Siri>", { status: 201, headers: {
        location: lock(receives), BrokerProperties: JSON.stringify({ LockedUntilUtc: new Date(Date.now() + 60_000).toISOString() }),
      } })
        : new Response(null, { status: 204 });
    }
    expect(String(input)).toMatch(/\/messages\/\d+\/opaque-private-lock-\d+$/u);
    calls.push(init?.method === "DELETE" ? "complete" : "abandon");
    return new Response(null, { status: failure === "complete" && init?.method === "DELETE" ? 503 : 200 });
  });
  return calls;
}

describe("isolated Denmark realtime Worker in native Workerd", () => {
  it("authenticates health/refresh and does no startup network work", async () => {
    expect((await worker.fetch(request("/health", "GET", ""), bindings)).status).toBe(401);
    expect((await worker.fetch(request("/refresh", "POST", "Bearer wrong"), bindings)).status).toBe(401);
    expect((await send("/refresh")).status).toBe(405);
    expect((await worker.fetch(request("/refresh", "POST", `Bearer ${secret}`, "{}"), bindings)).status).toBe(400);
    expect(await (await send("/health")).json()).toEqual({ configured: true, maintenance: null, corruptState: false });
    expect(fetch).not.toHaveBeenCalled();
  });

  it("does not reserve or mint tokens when configuration is incomplete", async () => {
    const missing = { ...bindings, DENMARK_SERVICEBUS_CLIENT_SECRET: "" };
    expect((await worker.fetch(request("/refresh", "POST"), missing)).status).toBe(503);
    expect((await worker.fetch(request("/health"), { ...bindings, RAIL_DATA_REFRESH_SECRET: "" })).status).toBe(503);
    const ctx = createExecutionContext(); await worker.scheduled({} as ScheduledController, missing, ctx); await waitOnExecutionContext(ctx);
    expect(fetch).not.toHaveBeenCalled();
  });

  it("accepts an actually empty network stream with Content-Length0", async () => {
    transport();
    const body = new ReadableStream<Uint8Array>({ start(controller) { controller.close(); } });
    const input = new Request("https://consumer.test/refresh", { method: "POST", body,
      headers: { authorization: `Bearer ${secret}`, "content-length": "0" } }) as Incoming;
    expect((await worker.fetch(input, bindings)).status).toBe(200);
  });

  it("rejects and cancels nonempty chunked bytes even when a zero length was declared", async () => {
    let cancelled = false;
    const body = new ReadableStream<Uint8Array>({ start(controller) { controller.enqueue(new Uint8Array([1])); }, cancel() { cancelled = true; } });
    const input = new Request("https://consumer.test/refresh", { method: "POST", body,
      headers: { authorization: `Bearer ${secret}`, "content-length": "0" } }) as Incoming;
    expect((await worker.fetch(input, bindings)).status).toBe(400); expect(cancelled).toBe(true);
    expect(fetch).not.toHaveBeenCalled();
  });

  it("cancels a stalled refresh body within its bounded read deadline", async () => {
    let cancelled = false;
    const body = new ReadableStream<Uint8Array>({ cancel() { cancelled = true; } });
    const input = new Request("https://consumer.test/refresh", { method: "POST", body, headers: { authorization: `Bearer ${secret}` } }) as Incoming;
    expect((await worker.fetch(input, bindings)).status).toBe(400); expect(cancelled).toBe(true);
    expect(fetch).not.toHaveBeenCalled();
  });

  it("uses the primary scheduled watchdog exactly once without adding it to the DO batch budget", async () => {
    transport(); const normal = vi.mocked(fetch).getMockImplementation()!; let watchdogs = 0;
    vi.mocked(fetch).mockImplementation(async (input, init) => {
      if (String(input) !== denmarkRegionalWatchdogURL) return normal(input, init);
      watchdogs++;
      expect(new Request(String(input), init).redirect).toBe("manual");
      expect(init?.method).toBe("POST"); expect(init?.body).toBeUndefined();
      expect(new Headers(init?.headers).get("authorization")).toBe(`Bearer ${secret}`);
      expect(new Headers(init?.headers).get(denmarkWatchdogHeader)).toBe("1");
      return Response.json({ accepted: true, wakeScheduled: true });
    });
    const ctx = createExecutionContext();
    await worker.scheduled({} as ScheduledController, { ...bindings, DENMARK_REGIONAL_WATCHDOG_URL: denmarkRegionalWatchdogURL }, ctx);
    await waitOnExecutionContext(ctx); expect(watchdogs).toBe(1);
  });

  it("lets a regional watchdog POST arm its own alarm promptly without forwarding or fetching provider data", async () => {
    const input = new Request("https://consumer.test/refresh", { method: "POST", headers: {
      authorization: `Bearer ${secret}`, [denmarkWatchdogHeader]: "1",
    } }) as Incoming;
    expect(await (await worker.fetch(input, { ...bindings, DENMARK_REGIONAL_WATCHDOG_URL: denmarkRegionalWatchdogURL })).json())
      .toEqual({ accepted: true, wakeScheduled: true });
    expect(fetch).not.toHaveBeenCalled();
    expect(await runInDurableObject(bindings.DENMARK_REALTIME.getByName("global"), (_instance, state) => state.storage.getAlarm())).toBe(at);
    const calls = transport();
    expect(await runDurableObjectAlarm(bindings.DENMARK_REALTIME.getByName("global"))).toBe(true);
    expect(calls).not.toContain(denmarkRegionalWatchdogURL);
  });

  it("keeps repeated HTTP and RPC refreshes wake-only across object recreation", async () => {
    const calls = transport();
    for (let attempt = 0; attempt < 3; attempt++) {
      expect(await (await send("/refresh", "POST")).json()).toEqual({ accepted: true, wakeScheduled: true });
    }
    await runInDurableObject(stub(), async (_instance, state) => {
      const recreated = new DenmarkRealtime(state, bindings);
      expect(await recreated.refresh()).toEqual({ wakeScheduled: true });
      expect(await state.storage.getAlarm()).toBe(at);
    });
    expect(calls).toEqual([]);
    expect(await runDurableObjectAlarm(stub())).toBe(true);
    expect(await health()).toMatchObject({ maintenance: { outcome: "empty", received: 1, completed: 1, abandoned: 0, backlog: "empty" } });
    expect(calls).toEqual(["oauth", "receive", "receive", "publish", "complete"]);
    vi.setSystemTime(at + 9_999); await send("/refresh", "POST");
    expect(calls).toHaveLength(5);
    vi.setSystemTime(at + 10_000); const ctx = createExecutionContext();
    await worker.scheduled({} as ScheduledController, bindings, ctx); await waitOnExecutionContext(ctx);
    expect(calls).toHaveLength(5); // Even cron only wakes the existing native alarm.
    expect(await runDurableObjectAlarm(stub())).toBe(true);
    expect(calls).toEqual(["oauth", "receive", "receive", "publish", "complete", "receive"]);
    expect(await (await send("/health")).text()).not.toMatch(/private|https|fixture-token|test-secret/u);
  });

  it("continues bounded backlog batches through native alarms, then backs off an empty queue", async () => {
    const calls = transport("backlog");
    expect(await drain()).toMatchObject({ maintenance: { outcome: "bounded", completed: 112, nextDueAt: at + 1_000 } });
    expect(calls).toHaveLength(233); // OAuth +112 receives +eight atomic publications +112 completions.
    expect(await runInDurableObject(stub(), (_instance, state) => state.storage.getAlarm())).toBe(at + 1_000);
    await send("/refresh", "POST"); expect(calls).toHaveLength(233);
    vi.setSystemTime(at + 1_000); expect(await runDurableObjectAlarm(stub())).toBe(true);
    expect(calls).toHaveLength(234);
    expect(await health()).toMatchObject({ maintenance: { outcome: "empty", completed: 0, nextDueAt: at + 11_000 } });
    expect(await runInDurableObject(stub(), (_instance, state) => state.storage.getAlarm())).toBe(at + 11_000);
  });

  it("keeps a legacy interrupted lease across recreation and recovers at its original deadline", async () => {
    const calls = transport(); await drain();
    await runInDurableObject(stub(), async (instance, state) => {
      const saved = await state.storage.get<Record<string, unknown>>("denmark-realtime-poll:v1");
      await state.storage.put("denmark-realtime-poll:v1", { ...saved, outcome: "running", finishedAt: null, nextDueAt: at + 55_000 });
      await state.storage.deleteAlarm();
      Reflect.set(instance, "maintenance", Reflect.get(new DenmarkRealtime(state, bindings), "maintenance"));
    });
    vi.setSystemTime(at + 54_999); await send("/refresh", "POST");
    expect(await runInDurableObject(stub(), (_instance, state) => state.storage.getAlarm())).toBe(at + 55_000);
    expect(await runDurableObjectAlarm(stub())).toBe(true); // Early delivery preserves the old lease.
    expect(calls).toHaveLength(5);
    vi.setSystemTime(at + 55_000); expect(await runDurableObjectAlarm(stub())).toBe(true);
    expect(await health()).toMatchObject({ maintenance: { outcome: "empty" } });
    expect(calls).toHaveLength(7); // Recreated consumer mints OAuth, then receives 204.
  });

  it.each(["publish", "complete"] as const)("abandons and stops after %s failure with safe persisted diagnostics", async failure => {
    const calls = transport(failure);
    const text = JSON.stringify(await drain());
    expect(JSON.parse(text)).toMatchObject({ maintenance: { outcome: "failed", received: 1, completed: 0, abandoned: 1, phase: failure } });
    expect(calls).toEqual(failure === "publish" ? ["oauth", "receive", "receive", "publish", "abandon"]
      : ["oauth", "receive", "receive", "publish", "complete", "abandon"]);
    expect(text).not.toMatch(/private|https|fixture-token|test-secret/u);
    await send("/refresh", "POST"); expect(calls.at(-1)).toBe("abandon");
  });

  it.each(["oauth", "network"] as const)("redacts %s failures without completing or erasing the persisted retry deadline", async failure => {
    const calls = transport(failure);
    const text = JSON.stringify(await drain());
    expect(JSON.parse(text)).toMatchObject({ maintenance: { outcome: "failed", received: 0, completed: 0, phase: "oauth" } });
    expect(text).not.toMatch(/private|https|fixture-token|test-secret/u);
    const count = vi.mocked(fetch).mock.calls.length; await send("/refresh", "POST");
    expect(fetch).toHaveBeenCalledTimes(count); expect(calls).not.toContain("complete");
  });
});
