import { DurableObject } from "cloudflare:workers";
import { createHash, timingSafeEqual } from "node:crypto";
import { compileMainlineGTFSPhases } from "../providers/mainline-gtfs-compiler.js";
import { gtfsRailCountries, gtfsRailSources, maximumGTFSRailIndexBytes, type GTFSRailCountry, type GTFSRailIndex } from "../providers/mainline-gtfs-index.js";
import { maintenanceRetryBody } from "./rail-maintenance-retry-body.js";
import type { GTFSIndexPublication } from "./mainline-gtfs-store.js";

export interface MainlineGTFSMaintenanceEnv {
  GTFS_MAINTENANCE: DurableObjectNamespace<MainlineGTFSMaintenance>;
  RAIL_DATA_REFRESH_SECRET?: string;
}
interface Attempt {
  country: GTFSRailCountry; startedAt: string; completedAt: string | null;
  outcome: "running" | "stored" | "unchanged" | "failed" | "retry-rejected";
  attemptsToday: number; stations: number; trips: number; downloadBytes: number; sourceHash: string | null;
  phase?: string;
}
const json = (value: unknown, status = 200) => Response.json(value,{ status, headers: { "cache-control": "no-store" } });
// A pre-publication manual check must not consume the next 20:10 UTC refresh.
const refreshWindow = (date: Date) => new Date(date.getTime() - (20*60+10)*60000).toISOString().slice(0,10);
async function receipt(response: Response): Promise<Partial<GTFSIndexPublication>> {
  const reader = response.body?.getReader();
  if (!reader) throw new Error("Missing publication receipt");
  const chunks: Uint8Array[] = []; let length = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read(); if (done) break;
      length += value.length;
      if (length > 2048) throw new Error("Oversized publication receipt");
      chunks.push(value);
    }
    const bytes = new Uint8Array(length); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk,offset); offset += chunk.length; }
    return JSON.parse(new TextDecoder("utf-8",{ fatal: true }).decode(bytes)) as Partial<GTFSIndexPublication>;
  } finally { await reader.cancel().catch(() => undefined); reader.releaseLock(); }
}

/** Large national archives run away from the interactive/API and watcher objects. */
export class MainlineGTFSMaintenance extends DurableObject<MainlineGTFSMaintenanceEnv> {
  private pending: Promise<Attempt> | null = null;
  private work: AsyncGenerator<{ phase: string },GTFSRailIndex> | null = null;
  private current: Attempt | null = null;
  private signal: AbortSignal | null = null;
  async health() { return await this.ctx.storage.get<Attempt>("attempt") ?? { outcome: "not-attempted" }; }
  async begin(country: GTFSRailCountry, retryFailedAttemptAt?: string): Promise<Attempt> {
    if (!gtfsRailCountries.includes(country)) throw new Error("Unsupported rail feed");
    const now = new Date();
    const gate = await this.ctx.storage.transaction(async transaction => {
      const previous = await transaction.get<Attempt>("attempt");
      const sameDay = previous !== undefined && refreshWindow(new Date(previous.startedAt)) === refreshWindow(now);
      const interrupted = previous?.outcome === "running" && now.getTime() - Date.parse(previous.startedAt) >= 150000;
      if (retryFailedAttemptAt !== undefined && (!sameDay || !(previous?.outcome === "failed" || interrupted)
        || previous.startedAt !== retryFailedAttemptAt || previous.attemptsToday >= 3)) return { run: false, attempt: { ...previous!, country, outcome: "retry-rejected" as const } };
      if (sameDay && retryFailedAttemptAt === undefined) return { run: false, attempt: previous! };
      const attempt: Attempt = { country, startedAt: now.toISOString(), completedAt: null, outcome: "running",
        attemptsToday: sameDay ? previous!.attemptsToday + 1 : 1, stations: 0, trips: 0, downloadBytes: 0, sourceHash: null, phase: "reserved" };
      await transaction.put("attempt",attempt);
      return { run: true, attempt };
    });
    if (!gate.run) return gate.attempt;
    this.current = gate.attempt; this.signal = AbortSignal.timeout(120000);
    this.work = this.compile(gate.attempt,this.signal);
    return gate.attempt;
  }
  private async *compile(result: Attempt, signal: AbortSignal): AsyncGenerator<{ phase: string },GTFSRailIndex> {
    const country = result.country;
    const response = await fetch(gtfsRailSources[country].url,{ signal, redirect: "follow", headers: { "user-agent": "TrainTrackerMainlineMaintenance/1.0" } });
    if (!response.ok || !response.body) { await response.body?.cancel(); throw new Error("Timetable download unavailable"); }
    const stream = response.body.pipeThrough(new TransformStream<Uint8Array,Uint8Array>({ transform(chunk,controller) {
      result.downloadBytes += chunk.byteLength; controller.enqueue(chunk);
    } }),{ signal });
    console.info("mainline_gtfs_phase",{ country, phase: "download-started" });
    return yield* compileMainlineGTFSPhases(stream,{ country, now: new Date(result.startedAt), signal,
      onPhase: (phase,counts) => console.info("mainline_gtfs_phase",{ country, phase, ...counts }) });
  }
  advance(startedAt: string): Promise<Attempt> {
    if (this.pending) return this.pending;
    const pending = this.advancePhase(startedAt).finally(() => { if (this.pending === pending) this.pending = null; });
    this.pending = pending; return pending;
  }
  private async advancePhase(startedAt: string): Promise<Attempt> {
    const previous = await this.ctx.storage.get<Attempt>("attempt");
    if (!previous || previous.startedAt !== startedAt) throw new Error("Retry rejected");
    if (previous.outcome !== "running") return previous;
    const result = this.current ?? previous, country = result.country;
    try {
      if (!this.work || !this.signal) throw new Error("Interrupted refresh");
      const step = await this.work.next();
      if (!step.done) {
        result.phase = step.value.phase;
        await this.ctx.storage.put("attempt",result);
        return result;
      }
      const index = step.value, signal = this.signal;
      const body = JSON.stringify(index);
      if (new TextEncoder().encode(body).length > maximumGTFSRailIndexBytes) throw new Error("Oversized timetable index");
      result.stations = index.stations.length; result.trips = index.trips.length; result.sourceHash = index.sourceHash;
      const published = await fetch(`https://roundhouse-api.example.invalid/internal/rail-data/mainline-gtfs/${country.toLowerCase()}`,{
        method: "POST", signal, redirect: "manual", body,
        headers: { "content-type": "application/json", authorization: `Bearer ${this.env.RAIL_DATA_REFRESH_SECRET!}` },
      });
      if (!published.ok) { await published.body?.cancel(); throw new Error("Timetable publication rejected"); }
      const acknowledgement = await receipt(published);
      if (!["stored","unchanged"].includes(acknowledgement.outcome ?? "") || acknowledgement.country !== country
        || acknowledgement.sourceHash !== index.sourceHash || acknowledgement.compiledAt !== index.compiledAt) throw new Error("Invalid publication receipt");
      result.outcome = acknowledgement.outcome as "stored" | "unchanged";
      result.phase = "completed";
    } catch { result.outcome = "failed"; }
    this.work = null; this.signal = null; this.current = null;
    result.completedAt = new Date().toISOString();
    await this.ctx.storage.put("attempt",result);
    return result;
  }
}

/** Each bounded phase is a separate Durable Object RPC, rather than one long CPU invocation. */
async function refresh(object: DurableObjectStub<MainlineGTFSMaintenance>, country: GTFSRailCountry, retry?: string): Promise<Attempt> {
  let result = await object.begin(country,retry);
  for (let phase = 0; result.outcome === "running" && phase < 3; phase++) result = await object.advance(result.startedAt);
  return result;
}

export default {
  async fetch(request: Request, env: MainlineGTFSMaintenanceEnv): Promise<Response> {
    const match = /^\/(tw|kr)\/(health|refresh)$/u.exec(new URL(request.url).pathname);
    if (!match) return json({ error: "not_found" },404);
    const expected = env.RAIL_DATA_REFRESH_SECRET;
    if (!expected || expected.length < 32) return json({ error: "not_configured" },503);
    const provided = request.headers.get("authorization") ?? "", digest = (value: string) => createHash("sha256").update(value).digest();
    if (provided.length > 512 || !timingSafeEqual(digest(provided),digest(`Bearer ${expected}`))) return json({ error: "unauthorized" },401);
    const isRefresh = match[2] === "refresh";
    if (request.method !== (isRefresh ? "POST" : "GET")) return json({ error: "method_not_allowed" },405);
    const country = match[1]!.toUpperCase() as GTFSRailCountry;
    const object = env.GTFS_MAINTENANCE.getByName(country);
    if (!isRefresh) return json(await object.health());
    const body = await maintenanceRetryBody(request);
    if (body instanceof Response) return body;
    try { const result = await refresh(object,country,body.retryFailedAttemptAt); return json(result,result.outcome === "retry-rejected" ? 409 : 200); }
    catch (error) {
      const rejected = error instanceof Error && /Retry rejected/u.test(error.message);
      const message = error instanceof Error ? error.message : "";
      console.error("mainline_gtfs_runtime_failure",{ category: rejected ? "retry-rejected" : "runtime",
        reason: /memory/iu.test(message) ? "memory-limit" : /cpu/iu.test(message) ? "cpu-limit" : "unclassified" });
      return json({ error: rejected ? "retry_rejected" : "maintenance_unavailable" },rejected ? 409 : 503);
    }
  },
  async scheduled(_controller: ScheduledController, env: MainlineGTFSMaintenanceEnv, ctx: ExecutionContext) {
    if ((env.RAIL_DATA_REFRESH_SECRET?.length ?? 0) >= 32) {
      for (const country of gtfsRailCountries) ctx.waitUntil(refresh(env.GTFS_MAINTENANCE.getByName(country),country));
    }
  },
} satisfies ExportedHandler<MainlineGTFSMaintenanceEnv>;
