import type { CanonicalTripReference, TripSnapshot } from "./snapshot.js";

export interface PlatformSampleTarget extends CanonicalTripReference {
  expiresAt: number;
}

export interface PlatformSamplingState {
  discoveryDue: boolean;
  canEnroll: boolean;
}

export interface PlatformSamplingRunReport {
  discoveryAttempted: boolean;
  targetsEnrolled: number;
  targetsPolled: number;
  observationsRecorded: number;
  failures: number;
}

export interface PlatformCorpusSamplingPersistence {
  samplingState(now: number): PlatformSamplingState;
  platformSampleSeen(id: string): boolean;
  duePlatformSamples(now: number, limit?: number): PlatformSampleTarget[];
  enrollPlatformSample(
    reference: CanonicalTripReference,
    departureAt: number,
    enrolledAt: number,
  ): PlatformSampleTarget | null;
  recordPlatformSampleSuccess(
    target: PlatformSampleTarget,
    snapshot: TripSnapshot,
    nextPollAt: number,
    complete: boolean,
    recordedAt: number,
  ): number;
  recordPlatformSampleFailure(target: PlatformSampleTarget, error: unknown, failedAt: number): void;
  recordPlatformSamplingRun(report: PlatformSamplingRunReport, recordedAt: number): void;
}
