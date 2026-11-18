import { describe, expect, it } from "vitest";
import { DenmarkServiceBusHttp } from "../src/providers/denmark-servicebus-http.js";

const expiry = Date.parse("2026-11-16T20:00:30.000Z");
const lock = "https://sb-duvproddistribution.servicebus.windows.net/topic/subscriptions/own/messages/77/opaque-lock";
async function receive(brokerProperties?: string) {
  const fetcher: typeof fetch = async input => String(input).includes("login.microsoftonline.com")
    ? Response.json({ access_token: "fixture-token", token_type: "Bearer", expires_in: 3600 })
    : new Response("<Siri/>", { status: 201, headers: { location: lock,
      ...(brokerProperties === undefined ? {} : { BrokerProperties: brokerProperties }) } });
  return new DenmarkServiceBusHttp("amqps://sb-duvproddistribution.servicebus.windows.net/topic/own", "client", "fixture-secret", fetcher)
    .receive(new AbortController().signal);
}

describe("bounded Service Bus lock-expiry metadata", () => {
  it.each([new Date(expiry).toUTCString(), "2026-11-16T20:00:30.000Z", "2026-11-16T20:00:30Z"])
    ("reads the explicit broker expiry %s without exposing its other metadata", async clock => {
      const result = await receive(JSON.stringify({ LockedUntilUtc: clock, MessageId: "private-id", LockToken: "private-token" }));
      expect(result?.lockExpiresAt).toBe(expiry);
      expect(Object.keys(result!).sort()).toEqual(["bytes", "lock", "lockExpiresAt"]);
    });

  it.each([undefined, "{", "null", "[]", JSON.stringify({ LockedUntilUtc: expiry }),
    JSON.stringify({ LockedUntilUtc: "2026-02-31T20:00:30Z" }),
    JSON.stringify({ LockedUntilUtc: "11/16/2026 20:00:30" }), " ".repeat(8193)])
    ("omits an absent, malformed or ambiguous expiry %s", async value => {
      const result = await receive(value);
      expect(result?.lockExpiresAt).toBeUndefined();
      expect(result?.lock).toBe(lock);
      expect(Object.keys(result!).sort()).toEqual(["bytes", "lock"]);
    });
});
