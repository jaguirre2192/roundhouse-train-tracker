/** Verified dataset785/789 wire subset: dated, partial SIRI-ET call forecasts only. */
export type DenmarkSiriOperatorRef = "DSB" | "DSB Vores Tog";
export function isDenmarkSiriOperatorRef(value: unknown): value is DenmarkSiriOperatorRef {
  return value === "DSB" || value === "DSB Vores Tog";
}

export interface DenmarkSiriCall {
  stopPointRef: string;
  aimedArrival: string | null;
  aimedDeparture: string | null;
  expectedArrival?: string;
  expectedDeparture?: string;
  observedAt: string;
  /** Equal source clocks with different content must not select an arbitrary forecast. */
  conflicted?: true;
}

export interface DenmarkSiriJourney {
  producerRef: string;
  responseTimestamp: string;
  receivedAt: string;
  operatorRef: DenmarkSiriOperatorRef;
  serviceDate: string;
  journeyRef: string;
  trainNumber: string;
  observedAt: string;
  completeStopSequence: boolean;
  calls: DenmarkSiriCall[];
}

export const denmarkSiriSourceName = "Rejseplanen SIRI-ET";
export const denmarkSiriMaximumAgeMilliseconds = 5 * 60_000;
export const denmarkSiriMaximumBodyBytes = 1024 * 1024;
