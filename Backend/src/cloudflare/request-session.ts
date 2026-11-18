import { sha256 } from "../gmail/gmail-crypto.js";
import type { TrainTrackerWatcher } from "./watcher-object.js";

export function bearerToken(request: Request): string | null {
  const header = request.headers.get("authorization");
  if (!header?.startsWith("Bearer ")) return null;
  return header.slice(7).trim();
}

export async function authenticatedUserId(
  request: Request,
  watcher: DurableObjectStub<TrainTrackerWatcher>,
): Promise<string | null> {
  const token = bearerToken(request);
  return token ? watcher.authUserIdForSession(await sha256(token)) : null;
}
