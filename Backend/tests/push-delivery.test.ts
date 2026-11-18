import { describe, expect, it } from "vitest";
import {
  APNsError,
  pushCollapseId,
  pushExpirationSeconds,
  pushHasExpired,
  type PushMessage,
  type PushSender,
} from "../src/apns/transport.js";
import type { MaterialEvent } from "../src/domain/events.js";
import { ProviderRegistry } from "../src/providers/provider.js";
import { WatcherCycle } from "../src/worker/watcher-cycle.js";
import type { OutboxMessage, WatcherPersistence } from "../src/worker/watcher-persistence.js";
import {
  FixedWindowRateLimiter,
  PublicReadRateLimiter,
  RateLimitExceededError,
} from "../src/services/journey-rate-limiter.js";

function event(overrides: Partial<MaterialEvent> = {}): MaterialEvent {
  return {
    kind: "platform-change",
    tripId: "us:amtraker:171-20@2026-07-20",
    stopId: "us:amtraker:NYP",
    title: "Platform changed",
    body: "Now platform 9.",
    oldValue: "8",
    newValue: "9",
    fingerprint: "a".repeat(64),
    ...overrides,
  };
}

function outbox(createdAt: number, overrides: Partial<OutboxMessage> = {}): OutboxMessage {
  return {
    id: "1",
    token: "f".repeat(64),
    environment: "sandbox",
    platform: "ios",
    payload: event(),
    createdAt,
    ...overrides,
  };
}

function cycleWith(messages: OutboxMessage[], sender: PushSender) {
  const failures: Array<{ id: string; permanent: boolean }> = [];
  const retired: string[] = [];
  const repository: WatcherPersistence = {
    claimDueTrips: async () => [],
    subscriptions: async () => [],
    recordSuccess: async () => {},
    recordFailure: async () => {},
    claimOutbox: async () => messages,
    markDelivered: async () => {},
    markDeliveryFailed: async (id, _error, permanent) => { failures.push({ id, permanent }); },
    retireDevice: async (token) => { retired.push(token); },
  };
  const cycle = new WatcherCycle(repository, new ProviderRegistry([]), sender, { info: () => {}, error: () => {} });
  return { cycle, failures, retired };
}

describe("APNs delivery policy", () => {
  it("treats configuration and token-topic failures as permanent but keeps transient ones retryable", () => {
    for (const [status, reason] of [
      [400, "BadDeviceToken"],
      [400, "DeviceTokenNotForTopic"],
      [400, "BadTopic"],
      [400, "TopicDisallowed"],
      [413, "PayloadTooLarge"],
      [403, "InvalidProviderToken"],
      [410, "Unregistered"],
    ] as const) {
      expect(new APNsError(status, reason).permanent, reason).toBe(true);
    }
    for (const [status, reason] of [
      [429, "TooManyRequests"],
      [500, "InternalServerError"],
      [503, "ServiceUnavailable"],
      [403, "ExpiredProviderToken"],
    ] as const) {
      expect(new APNsError(status, reason).permanent, reason).toBe(false);
    }
    expect(new APNsError(400, "DeviceTokenNotForTopic").invalidatesDevice).toBe(false);
  });

  it("anchors apns-expiration at the outbox creation time, not the attempt", () => {
    const createdAt = Date.parse("2026-07-20T16:00:00.000Z");
    const message: PushMessage = { token: "f".repeat(64), environment: "sandbox", platform: "ios", event: event(), createdAt };
    const later = createdAt + 10 * 60_000;
    expect(pushExpirationSeconds(message, later)).toBe(createdAt / 1_000 + 15 * 60);
    expect(pushHasExpired(message, later)).toBe(false);
    expect(pushHasExpired(message, createdAt + 16 * 60_000)).toBe(true);
    const delay: PushMessage = { ...message, event: event({ kind: "delay-threshold" }) };
    expect(pushHasExpired(delay, createdAt + 16 * 60_000)).toBe(false);
  });

  it("gives two different alerts for the same trip different collapse identities", () => {
    const first = event({ fingerprint: "1".repeat(64) });
    const second = event({ fingerprint: "2".repeat(64), newValue: "10" });
    expect(first.tripId).toBe(second.tripId);
    expect(pushCollapseId(first)).not.toBe(pushCollapseId(second));
    expect(pushCollapseId(first)).toBe(`platform-change:${"1".repeat(32)}`);
  });

  it("does not send an alert whose window closed while it waited for a retry", async () => {
    let sent = 0;
    const { cycle, failures } = cycleWith(
      [outbox(Date.now() - 20 * 60_000)],
      { send: async () => { sent += 1; } },
    );
    const report = await cycle.tick();
    expect(sent).toBe(0);
    expect(report.pushFailures).toBe(1);
    expect(failures).toEqual([{ id: "1", permanent: true }]);
  });

  it("fails a permanent APNs rejection instead of retrying it", async () => {
    const { cycle, failures, retired } = cycleWith(
      [outbox(Date.now())],
      { send: async () => { throw new APNsError(400, "DeviceTokenNotForTopic"); } },
    );
    await cycle.tick();
    expect(failures).toEqual([{ id: "1", permanent: true }]);
    expect(retired).toEqual([]);
  });

  it("retires the device and fails the message after Unregistered", async () => {
    const { cycle, failures, retired } = cycleWith(
      [outbox(Date.now())],
      { send: async () => { throw new APNsError(410, "Unregistered"); } },
    );
    await cycle.tick();
    expect(retired).toEqual(["f".repeat(64)]);
    expect(failures).toEqual([{ id: "1", permanent: true }]);
  });
});

describe("PublicReadRateLimiter", () => {
  it("limits each public read class per client key", () => {
    let now = Date.parse("2026-10-24T12:00:00.000Z");
    const limiter = new PublicReadRateLimiter(() => now);
    for (let index = 0; index < 30; index += 1) limiter.consume("stations", "client-a");
    expect(() => limiter.consume("stations", "client-a")).toThrow(RateLimitExceededError);
    expect(() => limiter.consume("stations", "client-b")).not.toThrow();
    expect(() => limiter.consume("snapshot", "client-a")).not.toThrow();
    now += 60_000;
    expect(() => limiter.consume("stations", "client-a")).not.toThrow();
  });

  it("reports the remaining window in the rejection", () => {
    const limiter = new FixedWindowRateLimiter({ only: 1 }, () => 1_000);
    limiter.consume("only", "client");
    try {
      limiter.consume("only", "client");
      expect.unreachable();
    } catch (error) {
      expect(error).toBeInstanceOf(RateLimitExceededError);
      expect((error as RateLimitExceededError).retryAfterSeconds).toBe(60);
      expect((error as Error).name).toBe("RateLimitExceededError");
    }
  });
});
