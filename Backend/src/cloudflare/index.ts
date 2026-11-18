import type { WorkerEnv } from "./env.js";
import { RequestValidationError } from "./api-validation.js";
import { coverageManifest } from "./coverage.js";
import { handleAuthRequest } from "./auth-routes.js";
import { handleForwardedEmail } from "./forwarding-email-handler.js";
import { handleForwardingRequest } from "./forwarding-routes.js";
import { retiredGmailResponse } from "./gmail-routes.js";
import { json, RequestBodyTooLargeError } from "./http.js";
import {
  MutationServiceUnavailableError,
  MutationUnauthorizedError,
} from "./mutation-security.js";
import {
  appleAppSiteAssociation,
  privacyPage,
  productPage,
  supportPage,
  termsPage,
} from "./public-pages.js";
import {
  canonicalPublicSiteRedirect,
  robotsResponse,
  sitemapResponse,
} from "./public-site.js";
import { handleRailRequest } from "./rail-routes.js";
import { handleArrivalBoards } from "./arrival-board-routes.js";
import { handleShareRequest } from "./share-routes.js";
import { handleJourneyRequest } from "./journey-routes.js";
import { handleLiveActivityRequest } from "./live-activity-routes.js";
import { handleRailDataRefresh } from "./rail-data-refresh-route.js";
import { isStorageWriteQuotaExceeded } from "./storage-availability.js";

export { TrainTrackerWatcher } from "./watcher-object.js";

export default {
  async fetch(request, env, _ctx): Promise<Response> {
    const url = new URL(request.url);
    const canonicalRedirect = canonicalPublicSiteRedirect(url);
    if (canonicalRedirect !== null) return canonicalRedirect;

    const path = url.pathname.replace(/\/$/u, "") || "/";

    try {
      if (request.method === "GET" && path === "/") return productPage();
      if (request.method === "GET" && path === "/robots.txt") return robotsResponse();
      if (request.method === "GET" && path === "/sitemap.xml") return sitemapResponse();
      if (request.method === "GET" && path === "/.well-known/apple-app-site-association") {
        return appleAppSiteAssociation();
      }
      if (request.method === "GET" && path === "/privacy") return privacyPage();
      if (request.method === "GET" && path === "/terms") return termsPage();
      if (request.method === "GET" && path === "/support") return supportPage();
      if (request.method === "GET" && path === "/v1/coverage") return json(coverageManifest);

      // Gmail import is retired: answer every Gmail path before it can reach OAuth,
      // the session exchange, scans, or stored tickets.
      const gmailRetired = retiredGmailResponse(path);
      if (gmailRetired !== null) return gmailRetired;

      const watcher = env.WATCHER.getByName("global");
      const refreshResponse = await handleRailDataRefresh(request, env, watcher, path);
      if (refreshResponse !== null) return refreshResponse;
      const authResponse = await handleAuthRequest(request, env, watcher, url, path);
      if (authResponse !== null) return authResponse;

      const forwardingResponse = await handleForwardingRequest(request, env, watcher, url, path);
      if (forwardingResponse !== null) return forwardingResponse;

      const arrivalBoard = await handleArrivalBoards(request, env, watcher, path);
      if (arrivalBoard !== null) return arrivalBoard;

      const shareResponse = await handleShareRequest(request, env, url, path);
      if (shareResponse !== null) return shareResponse;

      const journeyResponse = await handleJourneyRequest(request, env, watcher, url, path);
      if (journeyResponse !== null) return journeyResponse;

      const railResponse = await handleRailRequest(request, env, watcher, url, path);
      if (railResponse !== null) return railResponse;

      const liveActivityResponse = await handleLiveActivityRequest(request, env, watcher, url, path);
      if (liveActivityResponse !== null) return liveActivityResponse;

      return json({ error: "not_found" }, 404);
    } catch (error) {
      if (error instanceof RequestValidationError) {
        return json({ error: "invalid_request", details: error.issues }, 400);
      }
      if (error instanceof RequestBodyTooLargeError) {
        return json({ error: "request_too_large" }, 413);
      }
      if (error instanceof MutationUnauthorizedError) {
        console.info("mutation_metric", { operation: "unknown", outcome: "unauthorized" });
        return json({ error: "unauthorized" }, 401);
      }
      if (error instanceof MutationServiceUnavailableError) {
        console.info("mutation_metric", { operation: "unknown", outcome: "unavailable" });
        return json({ error: "service_unavailable" }, 503);
      }
      if (isStorageWriteQuotaExceeded(error)) {
        console.info("storage_write_quota_exceeded", { method: request.method, path });
        return json({ error: "service_unavailable" }, 503, {
          "retry-after": "300", "cache-control": "no-store",
        });
      }
      console.error("request failed", { method: request.method, path, error });
      return json({ error: "internal_error" }, 500);
    }
  },
  async scheduled(_controller, env, ctx): Promise<void> {
    const watcher = env.WATCHER.getByName("global");
    ctx.waitUntil(Promise.all([
      watcher.ensureScheduled(),
      watcher.pruneArrivalBoards(),
      watcher.retireGmailData(),
      watcher.samplePlatformCorpus(),
    ]));
  },
  async email(message, env, _ctx): Promise<void> {
    await handleForwardedEmail(message, env);
  },
} satisfies ExportedHandler<WorkerEnv>;
