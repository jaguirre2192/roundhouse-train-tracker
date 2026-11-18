import { describe, expect, it } from "vitest";
import { makeAPNsPayload } from "../src/apns/payload.js";

describe("makeAPNsPayload", () => {
  it("carries the exact run and typed values for a delivered train change", () => {
    const payload = makeAPNsPayload({
      kind: "delay-threshold", tripId: "eu:renfe:03123", serviceDate: "2026-11-18", stopId: "71801",
      title: "Train delayed", body: "Expected 25 minutes late.", oldValue: "0", newValue: "25",
      fingerprint: "delay-03123", timingEvent: "arrival",
    });
    expect(payload).toMatchObject({ eventServiceDate: "2026-11-18", eventOldValue: "0", eventNewValue: "25",
      eventTiming: "arrival", stopID: "71801" });
  });
  it("creates a visible time-sensitive alert with routing metadata", () => {
    const payload = makeAPNsPayload({
      kind: "platform-change",
      tripId: "eu:sncf:TGV123",
      stopId: "eu:sncf:FRPLY",
      title: "Platform changed",
      body: "Now platform 7.",
      oldValue: "6",
      newValue: "7",
      fingerprint: "event-123",
    });

    expect(payload.aps["interruption-level"]).toBe("time-sensitive");
    expect(payload).toMatchObject({ tripID: "eu:sncf:TGV123", eventID: "event-123", stopID: "eu:sncf:FRPLY" });
  });
});
