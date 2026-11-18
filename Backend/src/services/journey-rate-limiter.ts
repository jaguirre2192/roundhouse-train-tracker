export type JourneyRateClass = "places" | "search" | "resolve";
export type PublicReadRateClass = "snapshot" | "board" | "stations";

export class RateLimitExceededError extends Error {
  constructor(readonly retryAfterSeconds: number, message = "Rate limit exceeded") {
    super(message);
    this.name = "RateLimitExceededError";
  }
}

export class JourneyRateLimitError extends RateLimitExceededError {
  constructor(retryAfterSeconds: number) {
    super(retryAfterSeconds, "Journey rate limit exceeded");
    this.name = "JourneyRateLimitError";
  }
}

interface RateWindow {
  count: number;
  expiresAt: number;
}

const windowMilliseconds = 60_000;
const journeyLimits: Record<JourneyRateClass, number> = {
  places: 30,
  search: 12,
  resolve: 12,
};

/// Per-minute limits for the public provider-backed read endpoints. Each request
/// can reach an upstream provider, so a single network may not fan them out.
export const publicReadLimits: Record<PublicReadRateClass, number> = {
  snapshot: 60,
  board: 60,
  stations: 30,
};

/// Fixed one-minute windows keyed by rate class and an opaque client key.
export class FixedWindowRateLimiter<RateClass extends string> {
  private readonly windows = new Map<string, RateWindow>();

  constructor(
    private readonly limits: Record<RateClass, number>,
    private readonly now: () => number = Date.now,
    private readonly rejection: (retryAfterSeconds: number) => Error =
      (retryAfterSeconds) => new RateLimitExceededError(retryAfterSeconds),
  ) {}

  consume(rateClass: RateClass, clientKey: string): void {
    const now = this.now();
    this.discardExpired(now);
    const key = `${rateClass}:${clientKey}`;
    const current = this.windows.get(key);
    if (current === undefined) {
      this.windows.set(key, { count: 1, expiresAt: now + windowMilliseconds });
      return;
    }
    if (current.count >= this.limits[rateClass]) {
      const remaining = Math.max(1, Math.ceil((current.expiresAt - now) / 1_000));
      throw this.rejection(remaining);
    }
    current.count += 1;
  }

  private discardExpired(now: number): void {
    for (const [key, window] of this.windows) {
      if (window.expiresAt <= now) this.windows.delete(key);
    }
  }
}

export class JourneyRateLimiter extends FixedWindowRateLimiter<JourneyRateClass> {
  constructor(now: () => number = Date.now) {
    super(journeyLimits, now, (retryAfterSeconds) => new JourneyRateLimitError(retryAfterSeconds));
  }
}

export class PublicReadRateLimiter extends FixedWindowRateLimiter<PublicReadRateClass> {
  constructor(now: () => number = Date.now) {
    super(publicReadLimits, now);
  }
}
