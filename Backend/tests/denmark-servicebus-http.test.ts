import { afterEach, describe, expect, it, vi } from "vitest";
import { DenmarkServiceBusHttp, maximumDenmarkMessageBytes } from "../src/providers/denmark-servicebus-http.js";
import { publishDenmarkEvent } from "../src/cloudflare/denmark-realtime-publish.js";

const subscription = "amqps://sb-duvproddistribution.servicebus.windows.net/topic/own";
const lock = "https://sb-duvproddistribution.servicebus.windows.net/topic/subscriptions/own/messages/77/opaque-lock?api-version=2014-01";
const signal = () => new AbortController().signal;
const token = () => Response.json({ access_token: "fixture-token", token_type: "Bearer", expires_in: 3600 });
const message = (location = lock) => new Response("<Siri>source bytes</Siri>", { status: 201, headers: { location } });
afterEach(() => { vi.useRealTimers(); });

describe("Denmark own-subscription Service Bus HTTPS transport", () => {
  it("uses OAuth client_credentials, caches expiry and preserves opaque lock URLs for explicit settlement", async () => {
    let now = Date.parse("2026-11-16T20:00:00Z"), authCalls = 0;
    const settled: Array<[string, string]> = [];
    const fetcher = vi.fn<typeof fetch>(async (input, init) => {
      expect(init?.redirect).toBe("manual"); expect(init?.signal).toBeInstanceOf(AbortSignal);
      const url = new URL(String(input));
      if (url.hostname === "login.microsoftonline.com") {
        authCalls++; const body = new URLSearchParams(String(init?.body));
        expect(body.get("grant_type")).toBe("client_credentials"); expect(body.get("client_id")).toBe("client");
        expect(body.get("client_secret")).toBe("fixture-secret"); expect(body.get("scope")).toBe("https://servicebus.azure.net/.default");
        return token();
      }
      expect(new Headers(init?.headers).get("authorization")).toBe("Bearer fixture-token");
      if (init?.method === "POST") { expect(url.pathname).toBe("/topic/subscriptions/own/messages/head"); expect(url.searchParams.get("timeout")).toBe("1"); return message(); }
      settled.push([String(input), String(init?.method)]); return new Response(null, { status: 200 });
    });
    const client = new DenmarkServiceBusHttp(subscription, "client", "fixture-secret", fetcher, () => now);
    const first = await client.receive(signal()); expect(new TextDecoder().decode(first!.bytes)).toBe("<Siri>source bytes</Siri>");
    await client.settle(first!.lock, "complete"); await client.settle(first!.lock, "abandon");
    expect(settled).toEqual([[lock, "DELETE"], [lock, "PUT"]]); expect(authCalls).toBe(1);
    now += 3540_000; await client.receive(signal()); expect(authCalls).toBe(2);
  });

  it("invalidates an unauthorized cached bearer without retrying the failed receive", async () => {
    let authCalls = 0;
    const fetcher: typeof fetch = async (input) => {
      if (String(input).includes("login.microsoftonline.com")) { authCalls++; return token(); }
      return new Response("private provider error", { status: 401 });
    };
    const client = new DenmarkServiceBusHttp(subscription, "client", "fixture-secret", fetcher);
    await expect(client.receive(signal())).rejects.toMatchObject({ phase: "receive", code: "http", httpStatus: 401 });
    await expect(client.receive(signal())).rejects.toMatchObject({ code: "http" }); expect(authCalls).toBe(2);
  });

  it.each([
    ["<Error><Detail>Cannot Receive Large Messages using 'HTTP' protocol, private sequence</Detail></Error>", "requires-amqp"],
    ["private unrelated method error", "http"],
  ])("classifies only the explicit large-message405 without leaking its body", async (body, code) => {
    const fetcher: typeof fetch = async input => String(input).includes("login.microsoftonline.com")
      ? token() : new Response(body, { status: 405 });
    const error = await new DenmarkServiceBusHttp(subscription, "client", "fixture-secret", fetcher).receive(signal()).catch(error => error);
    expect(error).toMatchObject({ code, httpStatus: 405 });
    expect(String(error)).not.toMatch(/private|sequence|Detail/u);
  });

  it.each(["https://wrong.test/messages/1/private", "https://sb-duvproddistribution.servicebus.windows.net/topic/subscriptions/other/messages/1/private"])("rejects a foreign lock without sending credentials or reconstructing its URL", async (location) => {
    const fetcher = vi.fn<typeof fetch>(async input => String(input).includes("login.microsoftonline.com") ? token() : message(location));
    await expect(new DenmarkServiceBusHttp(subscription, "client", "fixture-secret", fetcher).receive(signal())).rejects.toMatchObject({ code: "invalid-lock" });
    expect(fetcher).toHaveBeenCalledTimes(2);
  });

  it("abandons an owned oversized message without deleting or publishing it", async () => {
    const methods: string[] = [];
    const fetcher: typeof fetch = async (input, init) => {
      if (String(input).includes("login.microsoftonline.com")) return token();
      methods.push(String(init?.method));
      return init?.method === "PUT" ? new Response(null, { status: 200 })
        : new Response("oversized", { status: 201, headers: { location: lock, "content-length": String(maximumDenmarkMessageBytes + 1) } });
    };
    await expect(new DenmarkServiceBusHttp(subscription, "client", "fixture-secret", fetcher).receive(signal())).rejects.toMatchObject({ code: "body-limit" });
    expect(methods).toEqual(["POST", "PUT"]);
  });

  it.each(["network", "auth-http", "malformed-token"])("redacts %s failures", async kind => {
    const fetcher: typeof fetch = async () => {
      if (kind === "network") throw new Error("https://private.test?secret=fixture-secret");
      return kind === "auth-http" ? new Response("fixture-secret", { status: 302 }) : Response.json({ access_token: "private" });
    };
    const error = await new DenmarkServiceBusHttp(subscription, "client", "fixture-secret", fetcher).receive(signal()).catch(error => error);
    expect(String(error)).not.toMatch(/private|fixture-secret|https/u); expect(error.phase).toBe("oauth");
  });

  it("bounds a never-resolving OAuth request even if transport ignores abort", async () => {
    vi.useFakeTimers();
    const client = new DenmarkServiceBusHttp(subscription, "client", "fixture-secret", async () => new Promise<Response>(() => {}));
    const pending = expect(client.receive(signal())).rejects.toMatchObject({ phase: "oauth", code: "deadline" });
    await vi.advanceTimersByTimeAsync(8_000); await pending;
  });
});

describe("durable Denmark ingestion acknowledgement", () => {
  it.each(["stored", "unchanged", "ignored-stale"])("accepts only explicit durable %s acknowledgements", async outcome => {
    const fetcher: typeof fetch = async (input, init) => {
      expect(String(input)).toBe("https://roundhouse-api.example.invalid/internal/rail-data/denmark-siri");
      expect(init?.redirect).toBe("manual"); expect(new Headers(init?.headers).get("authorization")).toBe("Bearer fixture-secret");
      expect(new TextDecoder().decode(init?.body as ArrayBuffer)).toBe("<Siri/>");
      return Response.json({ accepted: true, source: "denmark-siri", outcome });
    };
    await publishDenmarkEvent("fixture-secret", new TextEncoder().encode("<Siri/>"), signal(), fetcher);
  });
  it.each(["http", "html", "wrong-source", "not-accepted", "unknown-outcome", "oversized"])("rejects %s instead of permitting completion", async kind => {
    const fetcher: typeof fetch = async () => {
      if (kind === "http") return new Response(null, { status: 302 });
      if (kind === "html") return new Response("accepted");
      if (kind === "oversized") return new Response(" ".repeat(2049), { headers: { "content-type": "application/json" } });
      return Response.json({ accepted: kind !== "not-accepted", source: kind === "wrong-source" ? "other" : "denmark-siri",
        outcome: kind === "unknown-outcome" ? "queued" : "stored" });
    };
    await expect(publishDenmarkEvent("fixture-secret", new Uint8Array([60]), signal(), fetcher)).rejects.toHaveProperty("phase", "publish");
  });
});
