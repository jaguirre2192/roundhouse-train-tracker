import { afterEach, describe, expect, it, vi } from "vitest";
import { DenmarkBusError } from "../src/providers/denmark-servicebus-request.js";
import { maintenanceFixture as setup } from "./helpers/denmark-maintenance-fixture.js";

afterEach(() => vi.useRealTimers());

describe("Denmark bounded atomic publication", () => {
  it("holds every lock until the whole batch receives its durable acknowledgement", async () => {
    const s = setup(); let acknowledge!: () => void, entered!: () => void;
    const waiting = new Promise<void>(resolve => { entered = resolve; });
    s.publish.mockImplementationOnce(async messages => {
      entered(); await new Promise<void>(resolve => { acknowledge = resolve; });
      return { deliveries: messages.length, ignoredStale: 2 };
    });
    const pending = s.fire(); await waiting;
    expect(s.bus.receive).toHaveBeenCalledTimes(14);
    expect(s.bus.settle).not.toHaveBeenCalled();
    acknowledge();
    expect(await pending).toMatchObject({ maintenance: { completed: 14, ignoredStale: 2 } });
  });

  it("abandons all held messages after publication failure without completing any", async () => {
    const s = setup(); s.publish.mockRejectedValueOnce(new DenmarkBusError("publish", "http", 503));
    expect(await s.fire()).toMatchObject({ maintenance: { outcome: "failed", received: 14, completed: 0, abandoned: 14 } });
    expect(s.bus.settle.mock.calls.every(([, action]) => action === "abandon")).toBe(true);
    expect(s.events.length + 1).toBeLessThan(50); // Include a fresh OAuth exchange.
  });

  it("retains successful completions and abandons only the failed settlement", async () => {
    const s = setup();
    s.bus.settle.mockImplementation(async (lock, action) => {
      s.events.push(action);
      if (action === "complete" && lock === "private-lock-7") throw new DenmarkBusError("complete", "http", 503);
    });
    expect(await s.fire()).toMatchObject({ maintenance: { outcome: "failed", completed: 13, abandoned: 1 } });
    expect(s.bus.settle.mock.calls.filter(([, action]) => action === "abandon")).toEqual([["private-lock-7", "abandon", expect.any(AbortSignal)]]);
    expect(s.events.length + 1).toBeLessThan(50);
  });

  it("stays below 50 outbound requests even when all completions fail", async () => {
    const s = setup();
    s.bus.settle.mockImplementation(async (_lock, action) => {
      s.events.push(action); if (action === "complete") throw new DenmarkBusError("complete", "network");
    });
    expect(await s.fire()).toMatchObject({ maintenance: { completed: 0, abandoned: 14 } });
    expect(s.events.length + 1).toBe(44); // OAuth + 14 receive + publish + 14 complete + 14 abandon.
  });

  it.each([undefined, 20_000])("publishes a message with lock headroom %s without waiting for another receive", async headroom => {
    const s = setup(); let sequence = 0;
    s.bus.receive.mockImplementation(async () => {
      s.events.push("receive");
      return { bytes: new Uint8Array([60]), lock: `lock-${++sequence}`,
        ...(headroom === undefined ? {} : { lockExpiresAt: s.now() + headroom }) };
    });
    expect(await s.fire()).toMatchObject({ maintenance: { completed: 14 } });
    expect(s.events).toEqual(Array.from({ length: 14 }, () => ["receive", "publish", "complete"]).flat());
    expect(s.publish.mock.calls.every(([messages]) => messages.length === 1)).toBe(true);
    expect(s.events.length + 1).toBe(43);
  });

  it("abandons an already expiring lock without publishing or acknowledging it", async () => {
    const s = setup();
    s.bus.receive.mockResolvedValueOnce({ bytes: new Uint8Array([60]), lock: "expiring", lockExpiresAt: s.now() + 1_000 });
    expect(await s.fire()).toMatchObject({ maintenance: { outcome: "failed", failure: "invalid-lock", completed: 0, abandoned: 1 } });
    expect(s.publish).not.toHaveBeenCalled();
  });

  it.each([{ deliveries: 13, ignoredStale: 0 }, { deliveries: 14, ignoredStale: 15 }, { deliveries: 14, ignoredStale: NaN }])
  ("rejects a malformed batch acknowledgement %j before any completion", async receipt => {
    const s = setup(); s.publish.mockResolvedValueOnce(receipt);
    expect(await s.fire()).toMatchObject({ maintenance: { failure: "invalid-response", completed: 0, abandoned: 14 } });
  });

  it("publishes the bounded bytes and abandons the overflow candidate without deleting it", async () => {
    const s = setup(); let sequence = 0;
    s.bus.receive.mockImplementation(async () => ({ bytes: new Uint8Array(600_000), lock: `large-${++sequence}`, lockExpiresAt: s.now() + 60_000 }));
    expect(await s.fire()).toMatchObject({ maintenance: { outcome: "bounded", received: 2, completed: 1, abandoned: 1 } });
    expect(s.publish.mock.calls[0]![0]).toHaveLength(1);
    expect(s.bus.settle.mock.calls.map(([lock, action]) => [lock, action])).toEqual([["large-1", "complete"], ["large-2", "abandon"]]);
  });

  it("abandons earlier locks if a later receive fails during batch collection", async () => {
    const s = setup();
    s.bus.receive.mockResolvedValueOnce({ bytes: new Uint8Array([60]), lock: "held", lockExpiresAt: s.now() + 60_000 })
      .mockRejectedValueOnce(new DenmarkBusError("receive", "network"));
    expect(await s.fire()).toMatchObject({ maintenance: { outcome: "failed", received: 1, completed: 0, abandoned: 1 } });
    expect(s.publish).not.toHaveBeenCalled();
  });

  it("bounds a stalled publication by the earliest lock deadline, then abandons it", async () => {
    vi.useFakeTimers(); const s = setup();
    s.bus.receive.mockResolvedValueOnce({ bytes: new Uint8Array([60]), lock: "short", lockExpiresAt: s.now() + 3_000 });
    s.publish.mockImplementationOnce(() => new Promise(() => {}));
    const pending = s.fire(); await vi.advanceTimersByTimeAsync(2_000);
    expect(await pending).toMatchObject({ maintenance: { outcome: "failed", failure: "deadline", phase: "publish", completed: 0, abandoned: 1 } });
  });

  it("lets broker expiry recover a failed abandonment without logging the lock", async () => {
    const s = setup(); s.publish.mockRejectedValueOnce(new Error("private publisher response"));
    s.bus.settle.mockRejectedValue(new Error("private lock"));
    const result = await s.fire();
    expect(result).toMatchObject({ maintenance: { outcome: "failed", completed: 0, abandoned: 0, failure: "network" } });
    expect(JSON.stringify(result)).not.toMatch(/private|lock/u);
  });
});
