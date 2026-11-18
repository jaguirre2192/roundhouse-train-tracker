export type DenmarkBusPhase = "oauth" | "receive" | "publish" | "complete" | "abandon";
export type DenmarkBusFailure = "http" | "network" | "deadline" | "body-limit" | "invalid-response" | "invalid-lock" | "requires-amqp";

/** Only fixed codes and status numbers may leave the transport boundary. */
export class DenmarkBusError extends Error {
  constructor(readonly phase: DenmarkBusPhase, readonly code: DenmarkBusFailure, readonly httpStatus: number | null = null) {
    super(`Denmark realtime ${phase}: ${code}`); this.name = "DenmarkBusError";
  }
}

export async function denmarkOperation<T>(phase: DenmarkBusPhase, parent: AbortSignal | undefined,
  milliseconds: number, work: (signal: AbortSignal) => Promise<T>): Promise<T> {
  const controller = new AbortController();
  const abort = () => controller.abort();
  parent?.addEventListener("abort", abort, { once: true });
  if (parent?.aborted) abort();
  let rejectAbort: (() => void) | undefined;
  const interrupted = new Promise<never>((_, reject) => {
    rejectAbort = () => reject(new DenmarkBusError(phase, "deadline"));
    controller.signal.addEventListener("abort", rejectAbort, { once: true });
  });
  const timer = setTimeout(abort, milliseconds);
  try {
    if (controller.signal.aborted) throw new DenmarkBusError(phase, "deadline");
    return await Promise.race([work(controller.signal), interrupted]);
  } catch (error) {
    if (error instanceof DenmarkBusError) throw error;
    throw new DenmarkBusError(phase, controller.signal.aborted ? "deadline" : "network");
  } finally {
    clearTimeout(timer); parent?.removeEventListener("abort", abort);
    if (rejectAbort !== undefined) controller.signal.removeEventListener("abort", rejectAbort);
    controller.abort();
  }
}

export async function denmarkResponseBytes(response: Response, maximum: number, phase: DenmarkBusPhase): Promise<Uint8Array> {
  if (Number(response.headers.get("content-length")) > maximum) {
    await response.body?.cancel(); throw new DenmarkBusError(phase, "body-limit");
  }
  const reader = response.body?.getReader();
  if (reader === undefined) throw new DenmarkBusError(phase, "invalid-response");
  const chunks: Uint8Array[] = []; let length = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read(); if (done) break;
      length += value.byteLength;
      if (length > maximum) { await reader.cancel(); throw new DenmarkBusError(phase, "body-limit"); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(length); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return bytes;
}
