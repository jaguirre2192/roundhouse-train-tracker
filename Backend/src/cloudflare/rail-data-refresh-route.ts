import { createHash, timingSafeEqual } from "node:crypto";
import type { WorkerEnv } from "./env.js";
import type { TrainTrackerWatcher } from "./watcher-object.js";
import { json } from "./http.js";
import { maximumRegionalIndexBytes } from "../providers/trafiklab-regional-index-schema.js";
import { maximumGTFSRailIndexBytes, gtfsRailCountries } from "../providers/mainline-gtfs-index.js";
import { handleDenmarkSiriRefresh } from "./denmark-siri-refresh-route.js";

export async function handleRailDataRefresh(
  request: Request, env: WorkerEnv, watcher: DurableObjectStub<TrainTrackerWatcher>, path: string,
): Promise<Response | null> {
  const country = gtfsRailCountries.find(value => path === `/internal/rail-data/mainline-gtfs/${value.toLowerCase()}`);
  const denmark = path === "/internal/rail-data/denmark-siri";
  if (path !== "/internal/rail-data/trafiklab-skane" && !country && !denmark) return null;
  const maximumBytes = country ? maximumGTFSRailIndexBytes : maximumRegionalIndexBytes;
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const expected = env.RAIL_DATA_REFRESH_SECRET;
  if (expected === undefined || expected.length < 32) return json({ error: "not_configured" }, 503);
  const provided = request.headers.get("authorization") ?? "";
  const digest = (value: string) => createHash("sha256").update(value).digest();
  if (provided.length > 512 || !timingSafeEqual(digest(provided), digest(`Bearer ${expected}`))) {
    return json({ error: "unauthorized" }, 401);
  }
  if (denmark) return handleDenmarkSiriRefresh(request, watcher);
  if (!request.headers.get("content-type")?.toLowerCase().startsWith("application/json")) {
    return json({ error: "json_required" }, 415);
  }
  if (Number(request.headers.get("content-length")) > maximumBytes) return json({ error: "too_large" }, 413);
  if (request.body === null) return json({ error: "invalid_index" }, 400);
  const reader = request.body.getReader(), chunks: Uint8Array[] = [];
  let length = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      length += value.length;
      if (length > maximumBytes) { await reader.cancel(); return json({ error: "too_large" }, 413); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  let value: unknown;
  try {
    const bytes = new Uint8Array(length); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)) as unknown;
  } catch { return json({ error: "invalid_index" }, 400); }
  const result = country ? await watcher.updateMainlineGTFSIndex(country,value) : await watcher.updateSkaneRailIndex(value);
  return json(result, result.outcome === "invalid" ? 400 : result.outcome === "older" ? 409 : 200);
}
