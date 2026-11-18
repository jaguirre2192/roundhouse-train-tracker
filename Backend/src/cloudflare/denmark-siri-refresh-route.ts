import { denmarkSiriMaximumBodyBytes } from "../providers/denmark-siri-models.js";
import { json } from "./http.js";
import type { TrainTrackerWatcher } from "./watcher-object.js";
import { denmarkSiriBatchContentType, denmarkSiriBatchLimits, validDenmarkSiriBatch } from "./denmark-siri-batch.js";

/** Called only after the shared rail-data route's method/constant-time secret check. */
export async function handleDenmarkSiriRefresh(
  request: Request, watcher: Pick<TrainTrackerWatcher, "updateDenmarkSiri" | "updateDenmarkSiriBatch">,
): Promise<Response> {
  const contentType = request.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase();
  const batch = contentType === denmarkSiriBatchContentType;
  if (contentType !== "application/xml" && !batch) {
    return json({ error: "xml_required" }, 415);
  }
  const maximumBytes = batch ? denmarkSiriBatchLimits.bodyBytes : denmarkSiriMaximumBodyBytes;
  if (Number(request.headers.get("content-length")) > maximumBytes) return json({ error: "too_large" }, 413);
  if (request.body === null) return json({ error: "invalid_delivery" }, 400);
  const reader = request.body.getReader(), chunks: Uint8Array[] = [];
  let length = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > maximumBytes) { await reader.cancel(); return json({ error: "too_large" }, 413); }
      chunks.push(value);
    }
  } catch { return json({ error: "invalid_delivery" }, 400); }
  finally { reader.releaseLock(); }
  let xml: string, deliveries: string[] | undefined;
  try {
    const bytes = new Uint8Array(length); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    xml = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    if (batch) {
      const value = JSON.parse(xml) as { deliveries?: unknown } | null;
      if (value === null || !validDenmarkSiriBatch(value.deliveries)) return json({ error: "invalid_delivery" }, 400);
      deliveries = value.deliveries;
    }
  } catch { return json({ error: "invalid_delivery" }, 400); }
  try {
    const result = deliveries === undefined ? await watcher.updateDenmarkSiri(xml) : await watcher.updateDenmarkSiriBatch(deliveries);
    return json(result, result.accepted ? 200 : 400);
  } catch {
    return json({ error: "publication_failed" }, 500);
  }
}
