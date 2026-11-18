import type { DenmarkBusFailure, DenmarkBusPhase } from "../providers/denmark-servicebus-request.js";

export interface DenmarkPollState {
  reservedAt: number; leaseUntil: number; finishedAt: number | null; nextDueAt: number;
  outcome: "running" | "empty" | "bounded" | "failed";
  received: number; completed: number; abandoned: number; ignoredStale: number; durationMs: number | null;
  backlog: "unknown" | "empty" | "possibly-pending";
  phase: DenmarkBusPhase | null; failure: DenmarkBusFailure | null; httpStatus: number | null;
}
export const denmarkPollKey = "denmark-realtime-poll:v1";
export const denmarkMaximumDurationMs = 45_000;
// Free/legacy-Bundled safe: 14*(receive+publish+complete), OAuth, possible
// final empty receive and failure abandonment remain below 50 subrequests.
export const denmarkMaximumMessages = 14;
// Standard Workers Paid is verified for the deployed consumers. Keep each API
// publication at14, but amortize alarm/checkpoint overhead across eight groups.
export const denmarkPaidMaximumMessages = 112;

export function validDenmarkPollState(value: unknown): value is DenmarkPollState {
  if (typeof value !== "object" || value === null) return false;
  const state = value as DenmarkPollState;
  return Number.isFinite(state.reservedAt) && state.reservedAt >= 0
    && state.leaseUntil === state.reservedAt + 55_000
    && Number.isFinite(state.nextDueAt) && state.nextDueAt >= state.reservedAt
    && (state.finishedAt === null || (Number.isFinite(state.finishedAt) && state.finishedAt >= state.reservedAt))
    && ["running", "empty", "bounded", "failed"].includes(state.outcome)
    && [state.received, state.completed, state.abandoned, state.ignoredStale].every((count) => Number.isSafeInteger(count) && count >= 0 && count <= denmarkPaidMaximumMessages)
    && state.completed + state.abandoned <= state.received
    && state.ignoredStale <= state.received
    && (state.durationMs === null || (Number.isFinite(state.durationMs) && state.durationMs >= 0))
    && ["unknown", "empty", "possibly-pending"].includes(state.backlog)
    && (state.phase === null || ["oauth", "receive", "publish", "complete", "abandon"].includes(state.phase))
    && (state.failure === null || ["http", "network", "deadline", "body-limit", "invalid-response", "invalid-lock", "requires-amqp"].includes(state.failure))
    && (state.httpStatus === null || (Number.isInteger(state.httpStatus) && state.httpStatus >= 100 && state.httpStatus <= 599));
}
