import { afterEach, describe, expect, it, vi } from "vitest";
import { ProviderRequestPacer } from "../src/providers/provider-request-pacer.js";

afterEach(() => vi.useRealTimers());
describe("bounded provider request pacing", () => {
  it("spaces concurrent actual reservations and cannot wake into a reserved burst", async () => {
    vi.useFakeTimers(); vi.setSystemTime(0);
    const sent: number[] = [];
    const pacer = new ProviderRequestPacer(async () => { sent.push(Date.now()); return true; });
    const work = Promise.all([pacer.wait(), pacer.wait(), pacer.wait()]);
    await vi.advanceTimersByTimeAsync(1_000);
    await work;
    expect(sent).toEqual([0, 500, 1_000]);
  });

  it("waits for a persisted cooldown across a new local queue and bounds backpressure", async () => {
    vi.useFakeTimers(); vi.setSystemTime(0);
    let previous: number | null = null;
    const reserve = async () => {
      if (previous !== null && Date.now() - previous < 500) return false;
      previous = Date.now(); return true;
    };
    await new ProviderRequestPacer(reserve).wait();
    const recreated = new ProviderRequestPacer(reserve, 500, 1);
    const next = recreated.wait();
    await expect(recreated.wait()).rejects.toThrow("queue is full");
    await vi.advanceTimersByTimeAsync(500);
    await next;
    expect(previous).toBe(500);
  });
});
