import { DurableObject } from "cloudflare:workers";
import { createHash, timingSafeEqual } from "node:crypto";
import { maximumRegionalIndexBytes } from "../providers/trafiklab-regional-index-schema.js";
import { compileTrafiklabRegionalStatic } from "../providers/trafiklab-regional-static-compiler.js";
import { RegionalIndexMaintenance, RegionalIndexRetryRejected, type RegionalIndexPublishResult } from "./regional-index-maintenance.js";
import { maintenanceRetryBody } from "./rail-maintenance-retry-body.js";

export interface RailMaintenanceEnv {
  RAIL_MAINTENANCE: DurableObjectNamespace<RailMaintenance>;
  RAIL_DATA_REFRESH_SECRET?: string;
  TRAFIKLAB_GTFS_REGIONAL_STATIC_API_KEY?: string;
}
const publishURL = "https://roundhouse-api.example.invalid/internal/rail-data/trafiklab-skane";
const userAgent = "TrainTrackerMaintenance/1.0";
const configured = (env: RailMaintenanceEnv) => (env.RAIL_DATA_REFRESH_SECRET?.length ?? 0) >= 32
  && (env.TRAFIKLAB_GTFS_REGIONAL_STATIC_API_KEY?.trim().length ?? 0) > 0;
const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), {
  status, headers: { "content-type": "application/json", "cache-control": "no-store" },
});

async function publicationResult(response: Response): Promise<Partial<RegionalIndexPublishResult>> {
  const reader = response.body?.getReader();
  if (reader === undefined) throw new Error("Missing rail publication response");
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > 2_048) { await reader.cancel(); throw new Error("Rail publication response too large"); }
      chunks.push(value);
    }
    const bytes = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)) as Partial<RegionalIndexPublishResult>;
  } finally { reader.releaseLock(); }
}

export class RailMaintenance extends DurableObject<RailMaintenanceEnv> {
  private readonly maintenance: RegionalIndexMaintenance;

  constructor(ctx: DurableObjectState, env: RailMaintenanceEnv) {
    super(ctx, env);
    this.maintenance = new RegionalIndexMaintenance(ctx.storage, {
      loadIndex: async (signal, report) => {
        if (!configured(env)) throw new Error("Rail maintenance is not configured");
        const url = new URL("https://opendata.samtrafiken.se/gtfs/skane/skane.zip");
        url.searchParams.set("key", env.TRAFIKLAB_GTFS_REGIONAL_STATIC_API_KEY!.trim());
        report({ phase: "static-request", httpStatus: null, redirectStatus: null });
        const response = await fetch(url, { signal, redirect: "manual", headers: { "user-agent": userAgent } });
        report({ phase: "static-response", httpStatus: response.status,
          redirectStatus: response.status >= 300 && response.status < 400 ? response.status : null });
        if (!response.ok || response.body === null) {
          await response.body?.cancel();
          throw new Error("Regional static download failed");
        }
        let bytes = 0;
        const measured = response.body.pipeThrough(new TransformStream<Uint8Array, Uint8Array>({
          transform(chunk, controller) { bytes += chunk.byteLength; report({ downloadBytes: bytes }); controller.enqueue(chunk); },
          flush() { report({ downloadComplete: true }); },
        }), { signal });
        report({ phase: "compiling" });
        return compileTrafiklabRegionalStatic(measured, { signal });
      },
      publishIndex: async (index, signal, report) => {
        const body = JSON.stringify(index);
        if (new TextEncoder().encode(body).byteLength > maximumRegionalIndexBytes) return { outcome: "invalid" };
        const response = await fetch(publishURL, { method: "POST", signal, redirect: "manual", body, headers: {
          authorization: `Bearer ${env.RAIL_DATA_REFRESH_SECRET!}`,
          "content-type": "application/json", "user-agent": userAgent,
        } });
        report({ phase: "publish-response", httpStatus: response.status,
          redirectStatus: response.status >= 300 && response.status < 400 ? response.status : null });
        if (![200, 400, 409].includes(response.status)) {
          await response.body?.cancel();
          throw new Error("Rail index publication failed");
        }
        const result = await publicationResult(response);
        const allowed = response.status === 200 ? ["stored", "unchanged"] : response.status === 409 ? ["older"] : ["invalid"];
        if (result === null || !allowed.includes(result.outcome ?? "")) {
          throw new Error("Invalid rail index publication response");
        }
        if (result.outcome === "invalid") return { outcome: "invalid" };
        const versionTime = Date.parse(`${result.feedVersion}T00:00:00.000Z`);
        if (typeof result.feedVersion !== "string" || !/^\d{4}-\d{2}-\d{2}$/u.test(result.feedVersion)
          || !Number.isFinite(versionTime) || new Date(versionTime).toISOString().slice(0, 10) !== result.feedVersion) {
          throw new Error("Invalid rail index publication version");
        }
        if (response.status === 200 && result.feedVersion !== index.feedVersion) {
          throw new Error("Mismatched rail index publication version");
        }
        return { outcome: result.outcome!, ...(result.feedVersion === undefined ? {} : { feedVersion: result.feedVersion }) };
      },
    });
  }

  async health() { return { configured: configured(this.env), maintenance: await this.maintenance.health() }; }
  async refresh(retryFailedAttemptAt?: string) {
    if (!configured(this.env)) return this.health();
    try { return { configured: true, maintenance: await this.maintenance.run(retryFailedAttemptAt) }; }
    catch (error) {
      if (!(error instanceof RegionalIndexRetryRejected)) throw error;
      return { ...(await this.health()), retryRejected: true as const };
    }
  }
}

export default {
  async fetch(request: Request, env: RailMaintenanceEnv): Promise<Response> {
    const path = new URL(request.url).pathname;
    if (path !== "/health" && path !== "/refresh") return json({ error: "not_found" }, 404);
    const expected = env.RAIL_DATA_REFRESH_SECRET;
    if (expected === undefined || expected.length < 32) return json({ error: "not_configured" }, 503);
    const provided = request.headers.get("authorization") ?? "";
    const digest = (value: string) => createHash("sha256").update(value).digest();
    if (provided.length > 512 || !timingSafeEqual(digest(provided), digest(`Bearer ${expected}`))) {
      return json({ error: "unauthorized" }, 401);
    }
    if (request.method !== (path === "/health" ? "GET" : "POST")) return json({ error: "method_not_allowed" }, 405);
    if (path === "/refresh" && !configured(env)) return json({ error: "not_configured" }, 503);
    const body = path === "/refresh" ? await maintenanceRetryBody(request) : {};
    if (body instanceof Response) return body;
    const object = env.RAIL_MAINTENANCE.getByName("global");
    const result = await (path === "/health" ? object.health() : object.refresh(body.retryFailedAttemptAt));
    return json(result, "retryRejected" in result ? 409 : 200);
  },
  async scheduled(_controller: ScheduledController, env: RailMaintenanceEnv, ctx: ExecutionContext): Promise<void> {
    if (configured(env)) ctx.waitUntil(env.RAIL_MAINTENANCE.getByName("global").refresh());
  },
} satisfies ExportedHandler<RailMaintenanceEnv>;
