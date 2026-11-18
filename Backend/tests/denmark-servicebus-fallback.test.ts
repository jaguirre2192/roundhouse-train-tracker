import { describe, expect, it, vi } from "vitest";
import { DenmarkServiceBusFallback } from "../src/providers/denmark-servicebus-fallback.js";
import { DenmarkBusError } from "../src/providers/denmark-servicebus-request.js";

function setup() {
  const make = () => ({ receive: vi.fn(), settle: vi.fn(), close: vi.fn() });
  const http = make(), amqp = make();
  return { http, amqp, bus: new DenmarkServiceBusFallback(http, amqp), signal: new AbortController().signal };
}

describe("Denmark HTTP/AMQP lock ownership", () => {
  it("retains ordinary HTTP and its exact settlement owner", async () => {
    const s = setup(); s.http.receive.mockResolvedValue({ bytes: new Uint8Array([60]), lock: "http-lock" });
    await s.bus.receive(s.signal); await s.bus.settle("http-lock", "complete", s.signal);
    expect(s.http.settle).toHaveBeenCalledWith("http-lock", "complete", s.signal);
    expect(s.amqp.receive).not.toHaveBeenCalled();
  });

  it("uses AMQP only for a confirmed large-message barrier and retains ownership through retry", async () => {
    const s = setup(); s.http.receive.mockRejectedValue(new DenmarkBusError("receive", "requires-amqp", 405));
    s.amqp.receive.mockResolvedValue({ bytes: new Uint8Array([60]), lock: "real-amqp-lock", lockExpiresAt: 99 });
    expect(await s.bus.receive(s.signal)).toMatchObject({ lock: "real-amqp-lock", lockExpiresAt: 99 });
    s.amqp.settle.mockRejectedValueOnce(new Error("temporary"));
    await expect(s.bus.settle("real-amqp-lock", "complete", s.signal)).rejects.toThrow("temporary");
    await s.bus.settle("real-amqp-lock", "abandon", s.signal);
    expect(s.amqp.settle.mock.calls.map(([, action]) => action)).toEqual(["complete", "abandon"]);
    expect(s.http.settle).not.toHaveBeenCalled();
    await expect(s.bus.settle("real-amqp-lock", "complete")).rejects.toMatchObject({ code: "invalid-lock" });
  });

  it.each([401, 403, 405, 429, 503])("does not switch transport for an unclassified HTTP%s", async status => {
    const s = setup(); s.http.receive.mockRejectedValue(new DenmarkBusError("receive", "http", status));
    await expect(s.bus.receive(s.signal)).rejects.toMatchObject({ httpStatus: status });
    expect(s.amqp.receive).not.toHaveBeenCalled();
  });

  it("closes the alternate connection and rejects foreign locks", async () => {
    const s = setup(); await s.bus.close(); expect(s.amqp.close).toHaveBeenCalledOnce();
    await expect(s.bus.settle("foreign", "complete")).rejects.toMatchObject({ code: "invalid-lock" });
  });
});
