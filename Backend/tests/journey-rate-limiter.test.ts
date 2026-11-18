import { describe, expect, it } from "vitest";
import {
  JourneyRateLimiter,
  JourneyRateLimitError,
} from "../src/services/journey-rate-limiter.js";

describe("JourneyRateLimiter", () => {
  it("allows 30 place lookups per client in a fixed minute", () => {
    let now = Date.parse("2026-07-21T19:00:00.000Z");
    const limiter = new JourneyRateLimiter(() => now);

    for (let request = 0; request < 30; request += 1) {
      expect(() => limiter.consume("places", "hmac-client-a")).not.toThrow();
    }

    expect(() => limiter.consume("places", "hmac-client-a")).toThrowError(
      expect.objectContaining<Partial<JourneyRateLimitError>>({
        message: "Journey rate limit exceeded",
        retryAfterSeconds: 60,
      }),
    );

    now += 30_001;
    expect(() => limiter.consume("places", "hmac-client-a")).toThrowError(
      expect.objectContaining<Partial<JourneyRateLimitError>>({ retryAfterSeconds: 30 }),
    );

    now += 29_999;
    expect(() => limiter.consume("places", "hmac-client-a")).not.toThrow();
  });

  it("allows 12 searches and 12 resolutions in independent fixed windows", () => {
    const limiter = new JourneyRateLimiter(() => Date.parse("2026-07-21T19:00:00.000Z"));

    for (let request = 0; request < 12; request += 1) {
      limiter.consume("search", "hmac-client-a");
      limiter.consume("resolve", "hmac-client-a");
    }

    expect(() => limiter.consume("search", "hmac-client-a")).toThrow(JourneyRateLimitError);
    expect(() => limiter.consume("resolve", "hmac-client-a")).toThrow(JourneyRateLimitError);
  });

  it("isolates pseudonymous client keys and discards expired windows", () => {
    let now = Date.parse("2026-07-21T19:00:00.000Z");
    const limiter = new JourneyRateLimiter(() => now);

    for (let request = 0; request < 12; request += 1) {
      limiter.consume("search", "hmac-client-a");
    }

    expect(() => limiter.consume("search", "hmac-client-b")).not.toThrow();
    now += 60_000;
    expect(() => limiter.consume("search", "hmac-client-a")).not.toThrow();
  });
});
