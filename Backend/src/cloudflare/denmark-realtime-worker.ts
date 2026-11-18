import { DurableObject } from "cloudflare:workers";
import { createHash, timingSafeEqual } from "node:crypto";
import { DenmarkServiceBusHttp, denmarkSubscriptionEndpoint } from "../providers/denmark-servicebus-http.js";
import { DenmarkRealtimeMaintenance } from "./denmark-realtime-maintenance.js";
import { publishDenmarkBatch } from "./denmark-realtime-publish.js";
import { emptyDenmarkRefreshBody } from "./denmark-refresh-body.js";
import { wakeDenmarkRegionalConsumer } from "./denmark-realtime-watchdog.js";
import { denmarkPaidMaximumMessages } from "./denmark-realtime-poll-state.js";
import { DenmarkServiceBusAmqp } from "../providers/denmark-servicebus-amqp.js";
import { DenmarkServiceBusFallback } from "../providers/denmark-servicebus-fallback.js";

export interface DenmarkRealtimeEnv {
  DENMARK_REALTIME: DurableObjectNamespace<DenmarkRealtime>;
  DENMARK_SERVICEBUS_CLIENT_ID?: string;
  DENMARK_SERVICEBUS_CLIENT_SECRET?: string;
  DENMARK_SERVICEBUS_SUBSCRIPTION_URL?: string;
  RAIL_DATA_REFRESH_SECRET?: string;
  DENMARK_REGIONAL_WATCHDOG_URL?: string;
}
const json = (value: unknown, status = 200) => Response.json(value, { status, headers: { "cache-control": "no-store" } });
function configured(env: DenmarkRealtimeEnv): boolean {
  if (!(env.DENMARK_SERVICEBUS_CLIENT_ID?.trim()) || !(env.DENMARK_SERVICEBUS_CLIENT_SECRET?.trim())
    || (env.RAIL_DATA_REFRESH_SECRET?.length ?? 0) < 32) return false;
  try { denmarkSubscriptionEndpoint(env.DENMARK_SERVICEBUS_SUBSCRIPTION_URL ?? ""); return true; } catch { return false; }
}

export class DenmarkRealtime extends DurableObject<DenmarkRealtimeEnv> {
  private readonly maintenance: DenmarkRealtimeMaintenance;
  constructor(ctx: DurableObjectState, env: DenmarkRealtimeEnv) {
    super(ctx, env);
    const bus = configured(env) ? new DenmarkServiceBusFallback(
      new DenmarkServiceBusHttp(env.DENMARK_SERVICEBUS_SUBSCRIPTION_URL!, env.DENMARK_SERVICEBUS_CLIENT_ID!, env.DENMARK_SERVICEBUS_CLIENT_SECRET!),
      new DenmarkServiceBusAmqp(env.DENMARK_SERVICEBUS_SUBSCRIPTION_URL!, env.DENMARK_SERVICEBUS_CLIENT_ID!, env.DENMARK_SERVICEBUS_CLIENT_SECRET!),
    ) : null;
    this.maintenance = new DenmarkRealtimeMaintenance(ctx.storage, bus,
      (bytes, signal) => publishDenmarkBatch(env.RAIL_DATA_REFRESH_SECRET!, bytes, signal),
      () => Date.now(), denmarkPaidMaximumMessages);
  }
  health() { return this.maintenance.health(); }
  refresh() { return this.maintenance.wake(); }
  wake() { return this.maintenance.wake(); }
  async alarm() { await this.maintenance.runAlarm(); }
}

export default {
  async fetch(request: Request, env: DenmarkRealtimeEnv): Promise<Response> {
    const path = new URL(request.url).pathname;
    if (path !== "/health" && path !== "/refresh") return json({ error: "not_found" }, 404);
    const secret = env.RAIL_DATA_REFRESH_SECRET;
    if (secret === undefined || secret.length < 32) return json({ error: "not_configured" }, 503);
    const provided = request.headers.get("authorization") ?? "";
    const digest = (value: string) => createHash("sha256").update(value).digest();
    if (provided.length > 512 || !timingSafeEqual(digest(provided), digest(`Bearer ${secret}`))) return json({ error: "unauthorized" }, 401);
    if (request.method !== (path === "/health" ? "GET" : "POST")) return json({ error: "method_not_allowed" }, 405);
    if (path === "/refresh" && !configured(env)) return json({ error: "not_configured" }, 503);
    if (path === "/refresh" && !await emptyDenmarkRefreshBody(request)) return json({ error: "empty_body_required" }, 400);
    const object = env.DENMARK_REALTIME.getByName("global");
    if (path === "/refresh") {
      const result = await object.wake();
      return json({ accepted: result.wakeScheduled, ...result }, result.wakeScheduled ? 200 : 503);
    }
    return json(await object.health());
  },
  async scheduled(_controller: ScheduledController, env: DenmarkRealtimeEnv, ctx: ExecutionContext): Promise<void> {
    if (!configured(env)) return;
    ctx.waitUntil(env.DENMARK_REALTIME.getByName("global").wake());
    ctx.waitUntil(wakeDenmarkRegionalConsumer(env).then(result => {
      if (result.outcome === "failed") console.warn("Denmark regional watchdog failed", { failure: result.failure, httpStatus: result.httpStatus });
    }));
  },
} satisfies ExportedHandler<DenmarkRealtimeEnv>;
