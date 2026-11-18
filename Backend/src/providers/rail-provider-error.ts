/** A known upstream outage, distinct from a missing train or an internal bug. */
export class RailProviderUnavailableError extends Error {
  constructor(message = "Rail provider temporarily unavailable", readonly retryAfterSeconds = 60) {
    super(message);
    this.name = "RailProviderUnavailableError";
  }
}

// Durable Object RPC preserves the name but not the local prototype identity.
export function isRailProviderUnavailable(error: unknown): error is Error {
  return error instanceof Error && error.name === "RailProviderUnavailableError";
}

export function providerRetryAfter(error: Error): number {
  const value = "retryAfterSeconds" in error ? error.retryAfterSeconds : 60;
  return typeof value === "number" && Number.isFinite(value)
    ? Math.max(1, Math.min(300, Math.ceil(value))) : 60;
}
