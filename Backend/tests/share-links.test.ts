import { describe, expect, it } from "vitest";
import { createSharedTripToken, resolveSharedTripToken } from "../src/domain/share-links.js";

const secret = "a-long-random-share-link-secret";
const input = {
  trip: {
    id: "eu:transitous:trip-123",
    source: "transitous" as const,
    nativeId: "trip-123",
    serviceDate: "2026-08-03",
  },
  boardingStationId: "eu:transitous:fr-paris",
  alightingStationId: "eu:transitous:be-brussels",
};

describe("shared trip links", () => {
  it("round trips a public trip reference without ticket credentials", () => {
    const now = new Date("2026-07-21T00:00:00Z");
    const shared = createSharedTripToken(input, secret, now);

    expect(resolveSharedTripToken(shared.token, secret, now)).toEqual(shared.payload);
    expect(shared.token).not.toContain("paris");
  });

  it("rejects tampering and expired links", () => {
    const now = new Date("2026-07-21T00:00:00Z");
    const shared = createSharedTripToken(input, secret, now);
    const tampered = `${shared.token.slice(0, -1)}x`;

    expect(() => resolveSharedTripToken(tampered, secret, now)).toThrow();
    expect(() => resolveSharedTripToken(shared.token, secret, new Date("2026-09-01T00:00:00Z"))).toThrow(/expired/u);
  });
});
