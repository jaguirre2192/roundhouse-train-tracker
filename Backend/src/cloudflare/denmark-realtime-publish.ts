import { DenmarkBusError, denmarkOperation, denmarkResponseBytes } from "../providers/denmark-servicebus-request.js";
import { denmarkSiriBatchContentType, denmarkSiriBatchLimits } from "./denmark-siri-batch.js";
import { DenmarkSiriFragmentError, fragmentDenmarkSiriDelivery } from "../providers/denmark-siri-fragments.js";

const endpoint = "https://roundhouse-api.example.invalid/internal/rail-data/denmark-siri";
export type DenmarkPublishOutcome = "stored" | "unchanged" | "ignored-stale";
export interface DenmarkBatchPublishResult { deliveries: number; ignoredStale: number }

interface Acknowledgement { accepted?: unknown; source?: unknown; outcome?: unknown; deliveries?: unknown; ignoredStale?: unknown }

/** Queue settlement requires the protected API's explicit durable-ingest ACK. */
export function publishDenmarkEvent(secret: string, bytes: Uint8Array, parent: AbortSignal,
  fetcher: typeof fetch = (input, init) => fetch(input, init)): Promise<DenmarkPublishOutcome> {
  return publish(secret, bytes, "application/xml", parent, fetcher).then(result => result.outcome as DenmarkPublishOutcome);
}

/** Every broker lock in a batch waits for this one explicitly durable, count-matched ACK. */
export async function publishDenmarkBatch(secret: string, messages: readonly Uint8Array[], parent: AbortSignal,
  fetcher: typeof fetch = (input, init) => fetch(input, init)): Promise<DenmarkBatchPublishResult> {
  if (messages.length < 1 || messages.length > denmarkSiriBatchLimits.deliveries
    || messages.some(bytes => bytes.byteLength < 1)
    || messages.reduce((sum, bytes) => sum + bytes.byteLength, 0) > 20 * 1_024 * 1_024) {
    throw new DenmarkBusError("publish", "body-limit");
  }
  if (!messages.some(bytes => bytes.byteLength > denmarkSiriBatchLimits.xmlBytes)) {
    return publishAtomic(secret, messages, parent, fetcher);
  }
  let fragments: Uint8Array[][];
  try {
    const receivedAt = new Date().toISOString();
    // Validate every original's whole-journey fragments before the first API write.
    fragments = messages.map(bytes => fragmentDenmarkSiriDelivery(bytes, receivedAt));
  } catch (error) {
    throw new DenmarkBusError("publish", error instanceof DenmarkSiriFragmentError && error.code !== "invalid-xml"
      ? "body-limit" : "invalid-response");
  }
  let ignoredStale = 0;
  // Keep original deliveries separate here so fragment counts never masquerade
  // as broker counts. Native settlement waits for every original's complete ACK.
  for (const original of fragments) {
    let group: Uint8Array[] = [], size = 0, ignored = 0;
    const flush = async () => {
      if (group.length === 0) return;
      const result = await publishAtomic(secret, group, parent, fetcher);
      ignored += result.ignoredStale;
      group = []; size = 0;
    };
    for (const fragment of original) {
      if (group.length === denmarkSiriBatchLimits.deliveries || size + fragment.byteLength > denmarkSiriBatchLimits.xmlBytes) await flush();
      group.push(fragment); size += fragment.byteLength;
    }
    await flush();
    if (ignored === original.length) ignoredStale++;
  }
  return { deliveries: messages.length, ignoredStale };
}

async function publishAtomic(secret: string, messages: readonly Uint8Array[], parent: AbortSignal,
  fetcher: typeof fetch): Promise<DenmarkBatchPublishResult> {
  if (messages.reduce((sum, bytes) => sum + bytes.byteLength, 0) > denmarkSiriBatchLimits.xmlBytes) {
    throw new DenmarkBusError("publish", "body-limit");
  }
  let deliveries: string[];
  try { deliveries = messages.map(bytes => new TextDecoder("utf-8", { fatal: true }).decode(bytes)); }
  catch { throw new DenmarkBusError("publish", "invalid-response"); }
  const bytes = new TextEncoder().encode(JSON.stringify({ deliveries }));
  if (bytes.byteLength > denmarkSiriBatchLimits.bodyBytes) throw new DenmarkBusError("publish", "body-limit");
  const result = await publish(secret, bytes, denmarkSiriBatchContentType, parent, fetcher);
  if (result.deliveries !== deliveries.length || !Number.isSafeInteger(result.ignoredStale)
    || (result.ignoredStale as number) < 0 || (result.ignoredStale as number) > deliveries.length) {
    throw new DenmarkBusError("publish", "invalid-response");
  }
  return { deliveries: deliveries.length, ignoredStale: result.ignoredStale as number };
}

function publish(secret: string, bytes: Uint8Array, contentType: string, parent: AbortSignal,
  fetcher: typeof fetch): Promise<Acknowledgement> {
  return denmarkOperation("publish", parent, 8_000, async (signal) => {
    const response = await fetcher(endpoint, { method: "POST", redirect: "manual", signal,
      headers: { authorization: `Bearer ${secret}`, "content-type": contentType }, body: bytes.slice().buffer });
    if (response.status !== 200) {
      await response.body?.cancel(); throw new DenmarkBusError("publish", "http", response.status);
    }
    if (response.headers.get("content-type")?.split(";")[0]?.trim().toLowerCase() !== "application/json") {
      await response.body?.cancel(); throw new DenmarkBusError("publish", "invalid-response");
    }
    let result: Acknowledgement;
    try { result = JSON.parse(new TextDecoder().decode(await denmarkResponseBytes(response, 2_048, "publish"))); }
    catch (error) { if (error instanceof DenmarkBusError) throw error; throw new DenmarkBusError("publish", "invalid-response"); }
    if (result === null || result.accepted !== true || result.source !== "denmark-siri"
      || !["stored", "unchanged", "ignored-stale"].includes(String(result.outcome))) throw new DenmarkBusError("publish", "invalid-response");
    return result;
  });
}
