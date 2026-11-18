import { afterEach, describe, expect, it, vi } from "vitest";
import { DenmarkRealtimeMaintenance } from "../src/cloudflare/denmark-realtime-maintenance.js";
import { denmarkPollKey } from "../src/cloudflare/denmark-realtime-poll-state.js";
import { DenmarkBusError } from "../src/providers/denmark-servicebus-request.js";
import { DenmarkServiceBusHttp } from "../src/providers/denmark-servicebus-http.js";
import { maintenanceFixture as setup } from "./helpers/denmark-maintenance-fixture.js";

afterEach(() => vi.useRealTimers());

describe("alarm-owned Denmark queue draining", () => {
  it("only arms one alarm for concurrent/repeated watchdog calls and never fetches", async () => {
    const s = setup();
    expect(await Promise.all([s.consumer.wake(), s.consumer.wake(), s.consumer.wake()]))
      .toEqual(Array(3).fill({ wakeScheduled: true }));
    expect(s.writes).toEqual({ state: 0, alarm: 1 });
    expect(s.bus.receive).not.toHaveBeenCalled();
    expect(await s.create().wake()).toEqual({ wakeScheduled: true });
    expect(s.writes.alarm).toBe(1);
  });

  it("uses one final checkpoint and one next alarm for14 durably published messages", async () => {
    const s = setup();
    expect(await s.fire()).toMatchObject({ started: true, maintenance: { outcome: "bounded", completed: 14 } });
    expect(s.writes).toEqual({ state: 1, alarm: 1 });
    expect(s.publish).toHaveBeenCalledTimes(1);
    expect(s.events.slice(0,14)).toEqual(Array(14).fill("receive"));
    expect(s.events[14]).toBe("publish");
    expect(s.events.slice(15)).toEqual(Array(14).fill("complete"));
  });

  it("rejects another alarm while network work is pending and makes concurrent wakes write-free", async () => {
    const s = setup(); let resume!: () => void, entered!: () => void;
    const paused = new Promise<void>(resolve => { entered = resolve; });
    s.publish.mockImplementationOnce(async messages => { entered(); await new Promise<void>(resolve => { resume = resolve; });
      return { deliveries: messages.length, ignoredStale: 0 }; });
    const pending = s.fire(); await paused;
    expect(await s.consumer.runAlarm()).toMatchObject({ started: false });
    expect(await s.consumer.wake()).toEqual({ wakeScheduled: true });
    expect(s.writes).toEqual({ state: 0, alarm: 0 });
    expect(s.bus.settle).not.toHaveBeenCalled();
    resume(); expect(await pending).toMatchObject({ maintenance: { completed: 14 } });
  });

  it("preserves a legacy in-flight lease across migration and resumes only at55seconds", async () => {
    const s = setup(); await s.fire();
    const saved = await s.storage.get<Record<string, unknown>>(denmarkPollKey);
    s.setValue(denmarkPollKey, { ...saved, outcome: "running", finishedAt: null, nextDueAt: s.start + 55_000 });
    s.setTime(s.start + 54_999);
    expect(await s.fire(s.create())).toMatchObject({ started: false });
    expect(s.bus.receive).toHaveBeenCalledTimes(14);
    expect(s.alarm()).toBe(s.start + 55_000);
    s.setTime(s.start + 55_000);
    expect(await s.fire(s.create())).toMatchObject({ started: true });
    expect(s.bus.receive).toHaveBeenCalledTimes(28);
  });

  it("keeps the10second idle cadence across cold starts while checkpointing once per minute", async () => {
    const s = setup(); s.bus.receive.mockResolvedValue(null); await s.consumer.wake();
    for (let tick = 0; tick < 8_640; tick++) {
      s.setTime(s.start + tick * 10_000);
      expect(await s.fire(s.create())).toMatchObject({ maintenance: { outcome: "empty", nextDueAt: s.now() + 10_000 } });
      await s.create().wake(); // Each minute's watchdog is a subset of this worst-case call frequency.
    }
    expect(s.writes).toEqual({ state: 1_440, alarm: 8_641 });
    expect(s.publish).not.toHaveBeenCalled();
  });

  it("bounds busy-loop checkpoint cost to two writes per14 messages across recreation", async () => {
    const s = setup();
    for (let batch = 0; batch < 100; batch++) {
      s.setTime(s.start + batch * 1_000); await s.fire(s.create());
    }
    expect(s.writes).toEqual({ state: 100, alarm: 100 });
    expect(s.publish).toHaveBeenCalledTimes(100);
    expect(s.bus.settle).toHaveBeenCalledTimes(1_400);
  });

  it("rolls back the checkpoint if next-alarm commit fails and lets the native alarm retry", async () => {
    const s = setup(); s.bus.receive.mockResolvedValue(null); s.faults.alarm = true;
    await expect(s.fire()).rejects.toThrow("fixture alarm failure");
    expect(await s.storage.get(denmarkPollKey)).toBeUndefined();
    s.faults.alarm = false;
    expect(await s.fire(s.create())).toMatchObject({ maintenance: { outcome: "empty" } });
    expect(s.writes).toEqual({ state: 1, alarm: 1 });
  });

  it("keeps provider failure backoff durable and does not create tokens before it is due", async () => {
    const s = setup(); s.bus.receive.mockRejectedValueOnce(new DenmarkBusError("receive", "http", 429));
    expect(await s.fire()).toMatchObject({ maintenance: { outcome: "failed", httpStatus: 429, nextDueAt: s.start + 60_000 } });
    s.setTime(s.start + 59_999); expect(await s.fire(s.create())).toMatchObject({ started: false });
    expect(s.bus.receive).toHaveBeenCalledTimes(1);
  });

  it("ends hung transport before the45second alarm budget and persists a safe failure", async () => {
    vi.useFakeTimers(); const s = setup(); vi.setSystemTime(s.start);
    const fetcher: typeof fetch = async input => String(input).includes("login.microsoftonline.com")
      ? Response.json({ token_type: "Bearer", access_token: "fixture-token", expires_in: 3600 })
      : new Promise<Response>(() => {});
    const bus = new DenmarkServiceBusHttp("amqps://sb-duvproddistribution.servicebus.windows.net/topic/own", "client", "secret", fetcher);
    const consumer = new DenmarkRealtimeMaintenance(s.storage, bus, s.publish);
    const pending = consumer.runAlarm(); await vi.advanceTimersByTimeAsync(8_000);
    expect(await pending).toMatchObject({ maintenance: { outcome: "failed", phase: "receive", failure: "deadline", durationMs: 8_000 } });
  });

  it("fails closed on corrupt state and never fetches an unconfigured consumer", async () => {
    const s = setup(); s.setValue(denmarkPollKey, { reservedAt: NaN });
    expect(await s.fire()).toMatchObject({ started: false, corruptState: true });
    expect(await s.consumer.wake()).toEqual({ wakeScheduled: false });
    expect(await new DenmarkRealtimeMaintenance(s.storage, null, s.publish).wake()).toEqual({ wakeScheduled: false });
    expect(s.bus.receive).not.toHaveBeenCalled();
  });
});
