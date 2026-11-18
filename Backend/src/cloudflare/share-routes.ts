import { createSharedTripToken, resolveSharedTripToken } from "../domain/share-links.js";
import { parseSharedTrip } from "./api-validation.js";
import type { WorkerEnv } from "./env.js";
import { json, requestBody } from "./http.js";
import { sharedTripPage } from "./public-pages.js";

export async function handleShareRequest(
  request: Request,
  env: WorkerEnv,
  url: URL,
  path: string,
): Promise<Response | null> {
  const pageMatch = path.match(/^\/s\/(.+)$/u);
  if (request.method === "GET" && pageMatch?.[1] !== undefined) {
    if (env.SHARE_LINK_SECRET === undefined || env.SHARE_LINK_SECRET.length < 16) {
      return json({ error: "sharing_unavailable" }, 503);
    }
    try {
      // A malformed percent escape is an unknown link, not a server error.
      const token = decodeURIComponent(pageMatch[1]);
      const shared = resolveSharedTripToken(token, env.SHARE_LINK_SECRET);
      return sharedTripPage(shared.trip.id, shared.trip.serviceDate, token);
    } catch {
      return json({ error: "share_not_found" }, 404);
    }
  }

  if (request.method === "POST" && path === "/v1/shares") {
    if (env.SHARE_LINK_SECRET === undefined || env.SHARE_LINK_SECRET.length < 16) {
      return json({ error: "sharing_unavailable" }, 503);
    }
    const input = parseSharedTrip(await requestBody(request));
    const shared = createSharedTripToken(input, env.SHARE_LINK_SECRET);
    return json({ url: `${url.origin}/s/${shared.token}`, expiresAt: shared.payload.expiresAt }, 201);
  }

  const apiMatch = path.match(/^\/v1\/shares\/(.+)$/u);
  if (request.method === "GET" && apiMatch?.[1] !== undefined) {
    if (env.SHARE_LINK_SECRET === undefined || env.SHARE_LINK_SECRET.length < 16) {
      return json({ error: "sharing_unavailable" }, 503);
    }
    try {
      return json(resolveSharedTripToken(decodeURIComponent(apiMatch[1]), env.SHARE_LINK_SECRET));
    } catch {
      return json({ error: "share_not_found" }, 404);
    }
  }

  return null;
}
