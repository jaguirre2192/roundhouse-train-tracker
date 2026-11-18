import type { DenmarkBusClient, DenmarkLockedMessage } from "../providers/denmark-servicebus-http.js";
import { DenmarkBusError, denmarkOperation } from "../providers/denmark-servicebus-request.js";
import type { DenmarkBatchPublishResult } from "./denmark-realtime-publish.js";
import { denmarkSiriBatchLimits } from "./denmark-siri-batch.js";
import { denmarkMaximumDurationMs, denmarkMaximumMessages, type DenmarkPollState } from "./denmark-realtime-poll-state.js";

type Publisher = (messages: readonly Uint8Array[], signal: AbortSignal) => Promise<DenmarkBatchPublishResult>;
const publicationAndSettlementMs = 14_000; // 8s publish + 5s settlement + 1s clock margin.
const receiveBudgetMs = 18_000; // Includes HTTP barrier detection and a cold AMQP handshake.
const extraReceiveHeadroomMs = receiveBudgetMs + publicationAndSettlementMs;

/** Holds only bounded peek-lock messages. Every member is published atomically
 * before any member is completed. Failed/overflow locks are abandoned or expire. */
export async function drainDenmarkMessages(state: DenmarkPollState, bus: DenmarkBusClient,
  publish: Publisher, now: () => number, maximumMessages = denmarkMaximumMessages): Promise<void> {
  const end = state.reservedAt + denmarkMaximumDurationMs;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(0, end - now()));
  const held = new Set<DenmarkLockedMessage>();
  const receive = async () => {
    state.phase = "receive";
    const message = await denmarkOperation("receive", controller.signal, receiveBudgetMs, signal => bus.receive(signal));
    if (message !== null) { held.add(message); state.received++; state.backlog = "possibly-pending"; }
    return message;
  };
  const abandon = async () => {
    await Promise.all([...held].map(async message => {
      try {
        await denmarkOperation("abandon", undefined, 3_000, signal => bus.settle(message.lock, "abandon", signal));
        state.abandoned++;
      } catch { /* The broker's original expiry remains the recovery path. */ }
      held.delete(message);
    }));
  };
  try {
    while (state.received < maximumMessages && end - now() > extraReceiveHeadroomMs) {
      const first = await receive();
      if (first === null) { state.outcome = "empty"; state.backlog = "empty"; break; }
      const group = [first]; let bytes = first.bytes.byteLength, exhausted = false, overflow = false;
      while (group.length < denmarkSiriBatchLimits.deliveries && state.received < maximumMessages
        && canReceiveMore(group, end, now())) {
        const next = await receive();
        if (next === null) { exhausted = true; break; }
        if (bytes + next.bytes.byteLength > denmarkSiriBatchLimits.xmlBytes) { overflow = true; break; }
        group.push(next); bytes += next.bytes.byteLength;
      }
      const deadline = Math.min(end, ...group.flatMap(message =>
        message.lockExpiresAt === undefined ? [] : [message.lockExpiresAt - 1_000]));
      if (deadline <= now()) throw new DenmarkBusError("publish", "invalid-lock");
      state.phase = "publish";
      const large = group.some(message => message.bytes.byteLength > denmarkSiriBatchLimits.xmlBytes);
      const publicationBudget = large ? Math.min(20_000, deadline - now() - 5_000) : Math.min(8_000, deadline - now());
      if (publicationBudget <= 0) throw new DenmarkBusError("publish", "invalid-lock");
      const receipt = await denmarkOperation("publish", controller.signal, publicationBudget,
        signal => publish(group.map(message => message.bytes), signal));
      if (receipt.deliveries !== group.length || !Number.isSafeInteger(receipt.ignoredStale)
        || receipt.ignoredStale < 0 || receipt.ignoredStale > group.length) {
        throw new DenmarkBusError("publish", "invalid-response");
      }
      state.ignoredStale += receipt.ignoredStale;
      state.phase = "complete";
      const settlements = await Promise.allSettled(group.map(async message => {
        if (deadline <= now()) throw new DenmarkBusError("complete", "deadline");
        await denmarkOperation("complete", controller.signal, Math.min(5_000, deadline - now()),
          signal => bus.settle(message.lock, "complete", signal));
        held.delete(message); state.completed++;
      }));
      const failed = settlements.find(result => result.status === "rejected");
      if (failed?.status === "rejected") throw failed.reason;
      if (overflow) { await abandon(); state.outcome = "bounded"; break; }
      if (exhausted) { state.outcome = "empty"; state.backlog = "empty"; break; }
    }
    if (state.outcome === "running") state.outcome = "bounded";
  } catch (error) {
    const safe = error instanceof DenmarkBusError ? error : new DenmarkBusError(state.phase ?? "receive", "network");
    state.outcome = "failed"; state.phase = safe.phase; state.failure = safe.code; state.httpStatus = safe.httpStatus;
    await abandon();
  } finally { clearTimeout(timer); controller.abort(); }
}

function canReceiveMore(messages: readonly DenmarkLockedMessage[], end: number, now: number): boolean {
  // An unknown lease must be published promptly; never assume the broker's default TTL.
  if (messages.some(message => message.lockExpiresAt === undefined)) return false;
  return Math.min(end, ...messages.map(message => message.lockExpiresAt!)) - now > extraReceiveHeadroomMs;
}
