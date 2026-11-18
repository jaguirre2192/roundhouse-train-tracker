import type { ArrivalBoardRequest } from "../domain/arrival-board.js";
import { parseSharedTrip, RequestValidationError } from "./api-validation.js";
import { arrivalBoardAsset } from "./arrival-board-page.js";
import { boundedJSONBody, json } from "./http.js";
import { publicReadClientKey } from "./mutation-security.js";
import type { WorkerEnv } from "./env.js";
import type { TrainTrackerWatcher } from "./watcher-object.js";

function requestInput(value: unknown): ArrivalBoardRequest {
  const { trip } = parseSharedTrip(value);
  const input = value as Record<string, unknown>;
  if (typeof input.stationId !== "string" || !input.stationId.trim() || input.stationId.length > 500
    || typeof input.sequence !== "number" || !Number.isSafeInteger(input.sequence) || input.sequence < 0)
    throw new RequestValidationError(["Choose an arrival stop from this train."]);
  const note = input.note;
  if (note != null && (typeof note !== "string" || [...note].length > 180)) throw new RequestValidationError(["Meeting notes allow 180 characters."]);
  const zone = input.timeZone;
  if (zone != null) {
    if (typeof zone !== "string" || zone.length > 80) throw new RequestValidationError(["Invalid station time zone."]);
    try { new Intl.DateTimeFormat("en", { timeZone: zone }); }
    catch { throw new RequestValidationError(["Invalid station time zone."]); }
  }
  return { trip, stationId: input.stationId, sequence: input.sequence, timeZone: zone ?? null,
    note: typeof note === "string" ? note.trim() || null : null };
}

export async function handleArrivalBoards(request: Request, env: WorkerEnv, watcher: DurableObjectStub<TrainTrackerWatcher>, path: string): Promise<Response | null> {
  if (request.method === "GET" && path.startsWith("/meet")) return arrivalBoardAsset(path);
  if (request.method !== "POST" || (path !== "/v1/arrival-boards" && path !== "/v1/arrival-boards/status")) return null;
  const body = await boundedJSONBody(request, 8_192);
  const key = publicReadClientKey(request, env);
  try {
    if (path === "/v1/arrival-boards") {
      const result = await watcher.createArrivalBoard(requestInput(body), key);
      if (result.outcome === "unavailable") return json({ error: "provider_unavailable" }, 503, { "retry-after": "60" });
      if (result.outcome === "ended") return json({ error: "trip_ended" }, 410);
      if (result.outcome === "invalid_stop") return json({ error: "arrival_call_unavailable" }, 422);
      return json({ url: new URL("/meet#" + result.token, request.url).href, expiresAt: result.expiresAt }, 201);
    }
    const token = (body as { token?: unknown } | null)?.token;
    if (typeof token !== "string" || !/^[A-Za-z0-9_-]{43}$/u.test(token)) return json({ error: "board_closed" }, 410);
    const result = await watcher.readArrivalBoard(token, key);
    return result ? json(result) : json({ error: "board_closed" }, 410);
  } catch (error) {
    if (error instanceof Error && error.name === "RateLimitExceededError") return json({ error: "rate_limited" }, 429, { "retry-after": "60" });
    throw error;
  }
}
