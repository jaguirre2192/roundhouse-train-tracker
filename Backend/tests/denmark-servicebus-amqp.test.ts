import { afterEach, describe, expect, it, vi } from "vitest";
import type { ServiceBusClient, ServiceBusReceivedMessage } from "@azure/service-bus";
import { DenmarkServiceBusAmqp, maximumDenmarkAmqpMessageBytes, type DenmarkAmqpClientFactory } from "../src/providers/denmark-servicebus-amqp.js";
import { DenmarkServiceBusAuth, denmarkServiceBusScope } from "../src/providers/denmark-servicebus-auth.js";

const subscription = "amqps://sb-duvproddistribution.servicebus.windows.net/rail-main/test-main-office";
const lock = "12345678-abcd-abcd-abcd-123456789abc";
const now = 1794947450000;
const message = (body: unknown = new Uint8Array(1_507_730)) => ({ body, lockToken: lock,
  lockedUntilUtc: new Date(now + 60_000) }) as ServiceBusReceivedMessage;
function harness(messages = [message()]) {
  const receiver = { receiveMessages: vi.fn(async () => messages), abandonMessage: vi.fn(async (_message: ServiceBusReceivedMessage) => {}),
    completeMessage: vi.fn(async (_message: ServiceBusReceivedMessage) => {}), close: vi.fn(async () => {}) };
  const client = { createReceiver: vi.fn(() => receiver), close: vi.fn(async () => {}) };
  const factory = vi.fn<DenmarkAmqpClientFactory>(() => client as unknown as ServiceBusClient);
  const fetcher = vi.fn<typeof fetch>(async () => Response.json({ access_token: "test-token", token_type: "Bearer", expires_in: 120 }));
  const bus = new DenmarkServiceBusAmqp(subscription, "client-id", "client-secret", fetcher, () => now, factory);
  return { bus, receiver, client, factory, fetcher };
}
afterEach(() => vi.useRealTimers());

describe("Denmark original-message AMQP transport", () => {
  it("returns one untouched oversized body and the real broker lock with no automatic completion", async () => {
    const body = new Uint8Array(1_507_730), h = harness([message(body)]);
    const result = await h.bus.receive(new AbortController().signal);
    expect(result).toMatchObject({ lock, lockExpiresAt: now + 60_000 });
    expect(result!.bytes).toBe(body);
    expect(h.receiver.receiveMessages).toHaveBeenCalledWith(1, expect.objectContaining({ maxWaitTimeInMs: 1_000 }));
    expect(h.client.createReceiver).toHaveBeenCalledWith("rail-main", "test-main-office", {
      receiveMode: "peekLock", maxAutoLockRenewalDurationInMs: 0, skipParsingBodyAsJson: true,
    });
    expect(h.receiver.completeMessage).not.toHaveBeenCalled();
    await h.bus.settle(lock, "complete");
    expect(h.receiver.completeMessage.mock.calls[0]?.[0]?.body).toBe(body);
    await h.bus.close();
    expect(h.receiver.abandonMessage).not.toHaveBeenCalled();
  });

  it("uses actual OAuth expiry for both exact Azure Service Bus scope spellings and refuses other audiences", async () => {
    const h = harness([]); await h.bus.receive(new AbortController().signal);
    const [host, credential, options] = h.factory.mock.calls[0]!;
    expect(host).toBe("sb-duvproddistribution.servicebus.windows.net");
    expect(options.retryOptions).toEqual({ maxRetries: 0, timeoutInMs: 5_000 });
    for (const scope of [denmarkServiceBusScope, "https://servicebus.azure.net//.default"]) {
      await expect(credential.getToken(scope)).resolves.toEqual({ token: "test-token", expiresOnTimestamp: now + 120_000 });
    }
    expect(h.fetcher).toHaveBeenCalledTimes(1);
    await expect(credential.getToken("https://management.azure.com/.default")).rejects.toMatchObject({ phase: "oauth", code: "invalid-response" });
    await h.bus.close();
  });

  it("abandons the original on unsupported or over-limit bodies and never exposes SDK error details", async () => {
    for (const body of [new Uint8Array(maximumDenmarkAmqpMessageBytes + 1), {}, new Uint8Array()]) {
      const h = harness([message(body)]);
      await expect(h.bus.receive(new AbortController().signal)).rejects.toMatchObject({ phase: "receive" });
      expect(h.receiver.abandonMessage).toHaveBeenCalledTimes(1);
      expect(h.receiver.completeMessage).not.toHaveBeenCalled(); await h.bus.close();
    }
    const h = harness(); h.receiver.receiveMessages.mockRejectedValue(new Error("private-token secret-lock-url"));
    await expect(h.bus.receive(new AbortController().signal)).rejects.toThrow("Denmark realtime receive: network");
    await h.bus.close();
  });

  it("settles only locks acquired by this client and abandons a failed completion during close", async () => {
    const h = harness(); await h.bus.receive(new AbortController().signal);
    await expect(h.bus.settle("unknown", "complete")).rejects.toMatchObject({ code: "invalid-lock" });
    h.receiver.completeMessage.mockRejectedValue(new Error("network"));
    await expect(h.bus.settle(lock, "complete")).rejects.toMatchObject({ phase: "complete", code: "network" });
    await h.bus.close(); expect(h.receiver.abandonMessage).toHaveBeenCalledTimes(1);
    expect(h.receiver.close).toHaveBeenCalledTimes(1); expect(h.client.close).toHaveBeenCalledTimes(1);
    await h.bus.receive(new AbortController().signal); expect(h.factory).toHaveBeenCalledTimes(2); await h.bus.close();
  });

  it("abandons a delivery arriving after caller cancellation without returning it for publication", async () => {
    const h = harness(); let deliver!: (messages: ServiceBusReceivedMessage[]) => void;
    h.receiver.receiveMessages.mockImplementation(() => new Promise(resolve => { deliver = resolve; }));
    const controller = new AbortController(), pending = h.bus.receive(controller.signal);
    const rejected = expect(pending).rejects.toMatchObject({ phase: "receive", code: "deadline" });
    controller.abort(); await rejected; deliver([message()]);
    await vi.waitFor(() => expect(h.receiver.abandonMessage).toHaveBeenCalledTimes(1));
    await h.bus.close(); expect(h.receiver.completeMessage).not.toHaveBeenCalled();
  });

  it("bounds total close even if abandon and both SDK closes never resolve", async () => {
    vi.useFakeTimers(); const h = harness(); await h.bus.receive(new AbortController().signal);
    h.receiver.abandonMessage.mockImplementation(() => new Promise(() => {}));
    h.receiver.close.mockImplementation(() => new Promise(() => {})); h.client.close.mockImplementation(() => new Promise(() => {}));
    const closing = h.bus.close(); await vi.advanceTimersByTimeAsync(2_800); await closing;
    expect(h.receiver.close).toHaveBeenCalledTimes(1); expect(h.client.close).toHaveBeenCalledTimes(1);
    await expect(h.bus.settle(lock, "complete")).rejects.toMatchObject({ code: "invalid-lock" });
  });

  it("does no broker work for pre-aborted input and rejects foreign subscription configuration", async () => {
    const h = harness(), controller = new AbortController(); controller.abort();
    await expect(h.bus.receive(controller.signal)).rejects.toMatchObject({ code: "deadline" }); expect(h.factory).not.toHaveBeenCalled();
    expect(() => new DenmarkServiceBusAmqp(subscription.replace("windows.net", "example.com"), "id", "secret")).toThrow("Invalid Denmark subscription");
  });

  it("renews actual OAuth expiry after the existing refresh margin", async () => {
    let clock = now;
    const fetcher = vi.fn<typeof fetch>(async () => Response.json({ access_token: "opaque-token", token_type: "Bearer", expires_in: 120 }));
    const auth = new DenmarkServiceBusAuth("id", "secret", fetcher, () => clock);
    expect((await auth.accessToken()).expiresOnTimestamp).toBe(now + 120_000);
    clock += 61_000;
    expect((await auth.accessToken()).expiresOnTimestamp).toBe(clock + 120_000); expect(fetcher).toHaveBeenCalledTimes(2);
  });
});
