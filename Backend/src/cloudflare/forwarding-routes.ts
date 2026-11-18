import { authenticatedUserId } from "./request-session.js";
import type { WorkerEnv } from "./env.js";
import { ForwardingServiceUnavailableError, forwardingSecret } from "./forwarding-config.js";
import { json } from "./http.js";
import type { TrainTrackerWatcher } from "./watcher-object.js";

function decodeStandardBase64(value: string): ArrayBuffer {
  const binary = atob(value);
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

export async function handleForwardingRequest(
  request: Request,
  env: WorkerEnv,
  watcher: DurableObjectStub<TrainTrackerWatcher>,
  _url: URL,
  path: string,
): Promise<Response | null> {
  if (!path.startsWith("/v1/forwarding/")) return null;

  // Revoking an address or managing a previously imported ticket requires only the owning account.
  if (path.startsWith("/v1/forwarding/alias") && request.method !== "DELETE") {
    try {
      forwardingSecret(env);
    } catch (error) {
      if (error instanceof ForwardingServiceUnavailableError) return json({ error: "service_unavailable" }, 503);
      throw error;
    }
  }

  const userId = await authenticatedUserId(request, watcher);
  if (userId === null) return json({ error: "unauthorized" }, 401);

  if (path === "/v1/forwarding/alias") {
    if (request.method === "GET") return json(await watcher.forwardingAliasStatus(userId));
    if (request.method === "POST") return json(await watcher.createForwardingAlias(userId));
    if (request.method === "DELETE") {
      await watcher.revokeForwardingAlias(userId);
      return new Response(null, { status: 204 });
    }
  }

  if (request.method === "POST" && path === "/v1/forwarding/alias/rotate") {
    return json(await watcher.rotateForwardingAlias(userId));
  }

  if (request.method === "GET" && path === "/v1/forwarding/tickets") {
    return json(await watcher.forwardingTickets(userId));
  }

  const artifactMatch = path.match(/^\/v1\/forwarding\/tickets\/([^/]+)\/artifact$/u);
  if (request.method === "GET" && artifactMatch?.[1] !== undefined) {
    const artifact = await watcher.forwardingTicketArtifact(userId, decodeURIComponent(artifactMatch[1]));
    if (artifact === null) return json({ error: "artifact_not_found" }, 404);
    return new Response(decodeStandardBase64(artifact.data), {
      headers: {
        "content-type": artifact.mimeType,
        "content-disposition": `inline; filename="${artifact.filename.replace(/["\\\r\n]/gu, "_")}"`,
        "cache-control": "private, no-store",
      },
    });
  }

  const ticketMatch = path.match(/^\/v1\/forwarding\/tickets\/([^/]+)$/u);
  if (request.method === "DELETE" && ticketMatch?.[1] !== undefined) {
    const deleted = await watcher.deleteForwardingTicket(userId, decodeURIComponent(ticketMatch[1]));
    return deleted ? new Response(null, { status: 204 }) : json({ error: "ticket_not_found" }, 404);
  }

  return null;
}
