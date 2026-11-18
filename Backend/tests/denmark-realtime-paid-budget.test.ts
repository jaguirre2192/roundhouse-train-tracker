import { describe, expect, it, vi } from "vitest";
import { DenmarkRealtimeMaintenance } from "../src/cloudflare/denmark-realtime-maintenance.js";
import { denmarkPaidMaximumMessages } from "../src/cloudflare/denmark-realtime-poll-state.js";
import { DenmarkBusError } from "../src/providers/denmark-servicebus-request.js";
import { maintenanceFixture as setup } from "./helpers/denmark-maintenance-fixture.js";

describe("paid Denmark catch-up work bound", () => {
  it("allows the measured ten-second cold AMQP connection without exceeding the alarm budget", async () => {
    vi.useFakeTimers();
    try {
      const s = setup(denmarkPaidMaximumMessages);
      s.bus.receive.mockImplementationOnce(async () => {
        await new Promise(resolve => setTimeout(resolve, 10_000));
        s.setTime(s.start + 10_000);
        return { bytes: new Uint8Array([60]), lock: "cold-amqp", lockExpiresAt: s.now() + 30_000 };
      }).mockResolvedValueOnce(null);
      const pending = s.fire();
      await vi.advanceTimersByTimeAsync(10_000);
      expect(await pending).toMatchObject({ maintenance: { outcome: "empty", completed: 1, durationMs: 10_000 } });
      expect(s.bus.settle).toHaveBeenCalledWith("cold-amqp", "complete", expect.any(AbortSignal));
    } finally { vi.useRealTimers(); }
  });

  it("checkpoints eight bounded publications with only two consumer writes", async () => {
    const s = setup(denmarkPaidMaximumMessages);
    expect(await s.fire()).toMatchObject({ maintenance: { outcome: "bounded", received: 112, completed: 112 } });
    expect(s.publish).toHaveBeenCalledTimes(8);
    expect(s.publish.mock.calls.every(([messages]) => messages.length === 14)).toBe(true);
    expect(s.writes).toEqual({ state: 1, alarm: 1 });
    expect(s.events.length + 1).toBe(233); // Eight publications,112 receives/completions, OAuth.
    expect(await s.create().health()).toMatchObject({ corruptState: false, maintenance: { completed: 112 } });
  });

  it("keeps unknown broker leases unbatched and stays conservatively below1000 requests", async () => {
    const s = setup(denmarkPaidMaximumMessages); let serial = 0;
    s.bus.receive.mockImplementation(async () => {
      s.events.push("receive"); return { bytes: new Uint8Array([60]), lock: `unknown-${++serial}` };
    });
    expect(await s.fire()).toMatchObject({ maintenance: { completed: 112 } });
    expect(s.publish.mock.calls.every(([messages]) => messages.length === 1)).toBe(true);
    expect(s.events.length + 1).toBe(337);
  });

  it("retains the first durable group and abandons only the next failed group", async () => {
    const s = setup(denmarkPaidMaximumMessages);
    s.publish.mockResolvedValueOnce({ deliveries: 14, ignoredStale: 0 })
      .mockRejectedValueOnce(new DenmarkBusError("publish", "http", 503));
    expect(await s.fire()).toMatchObject({ maintenance: { outcome: "failed", received: 28, completed: 14, abandoned: 14 } });
    expect(s.bus.settle.mock.calls.filter(([, action]) => action === "complete")).toHaveLength(14);
    expect(s.bus.settle.mock.calls.filter(([, action]) => action === "abandon")).toHaveLength(14);
  });

  it("honors the45second work timer before the larger message bound", async () => {
    const s = setup(denmarkPaidMaximumMessages); let serial = 0;
    s.bus.receive.mockImplementation(async () => {
      s.setTime(s.now() + 1_000);
      return { bytes: new Uint8Array([60]), lock: `slow-${++serial}`, lockExpiresAt: s.now() + 60_000 };
    });
    const result = await s.fire();
    expect(result.maintenance?.outcome).toBe("bounded");
    expect(result.maintenance?.completed).toBeGreaterThan(0);
    expect(result.maintenance?.completed).toBeLessThan(112);
    expect(result.maintenance?.durationMs).toBeLessThan(45_000);
  });

  it.each([0, 113, NaN, 1.5])("rejects invalid work bound%s", maximum => {
    const s = setup();
    expect(() => new DenmarkRealtimeMaintenance(s.storage, s.bus, s.publish, s.now, maximum)).toThrow("work bound");
  });
});
