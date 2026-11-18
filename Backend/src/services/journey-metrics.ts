import type { ProviderSource } from "../domain/snapshot.js";
import type { JourneyRateClass } from "./journey-rate-limiter.js";

export type JourneyMetricProvider = ProviderSource | "multiple" | "none";
export type JourneyMetricOutcome = "success" | "partial_failure" | "failure";
export type JourneyMetricErrorClass =
  | "timeout"
  | "invalid_input"
  | "rate_limited"
  | "tracking_token_expired"
  | "not_found"
  | "provider_unavailable"
  | "unknown";

/** Aggregate operational data only. Sensitive request values have no representable field. */
export interface JourneyMetric {
  operation: JourneyRateClass;
  provider: JourneyMetricProvider;
  originCountryCode: string | null;
  destinationCountryCode: string | null;
  latencyMilliseconds: number;
  cacheHit: boolean;
  outcome: JourneyMetricOutcome;
  optionCount: number | null;
  errorClass: JourneyMetricErrorClass | null;
  zeroResults: boolean;
}

export interface JourneyMetricLogger {
  log(metric: JourneyMetric): void;
}
