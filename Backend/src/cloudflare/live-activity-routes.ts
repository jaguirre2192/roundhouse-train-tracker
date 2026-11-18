import type { WorkerEnv } from "./env.js";
import type { TrainTrackerWatcher } from "./watcher-object.js";
import { boundedJSONBody } from "./http.js";
import { mutationContext, mutationResponse } from "./mutation-security.js";
import { parseLiveActivityIdentity, parseLiveActivityRegistration } from "./live-activity-validation.js";

export async function handleLiveActivityRequest(request: Request, env: WorkerEnv,
  watcher: DurableObjectStub<TrainTrackerWatcher>, url: URL, path: string): Promise<Response | null> {
  if (request.method === "POST" && path === "/v1/live-activities") {
    const context = mutationContext(request, env);
    const input = parseLiveActivityRegistration(await boundedJSONBody(request, 16 * 1_024));
    return mutationResponse("register_live_activity", await watcher.registerLiveActivity(input, context));
  }
  const match = /^\/v1\/live-activities\/([^/]+)$/u.exec(path);
  if (request.method === "DELETE" && match !== null) {
    const context = mutationContext(request, env);
    const input = parseLiveActivityIdentity(url.searchParams.get("installationId"), match[1]);
    return mutationResponse("stop_live_activity", await watcher.stopLiveActivity(input.installationId, input.activityId, context));
  }
  return null;
}
