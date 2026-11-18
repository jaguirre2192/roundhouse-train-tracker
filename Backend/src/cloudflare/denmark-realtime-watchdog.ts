import { DenmarkBusError, denmarkOperation, denmarkResponseBytes } from "../providers/denmark-servicebus-request.js";

export const denmarkRegionalWatchdogURL = "https://roundhouse-regional.example.invalid/refresh";
export const denmarkWatchdogHeader = "x-denmark-consumer-watchdog";
export interface DenmarkWatchdogEnv { DENMARK_REGIONAL_WATCHDOG_URL?: string; RAIL_DATA_REFRESH_SECRET?: string }

/** One exact credential destination, one empty POST, no redirects or retries.
 * The target only arms its alarm; it does not run a batch in this request. */
export async function wakeDenmarkRegionalConsumer(env: DenmarkWatchdogEnv) {
  if (!env.DENMARK_REGIONAL_WATCHDOG_URL) return { outcome: "disabled" as const, httpStatus: null };
  if (env.DENMARK_REGIONAL_WATCHDOG_URL !== denmarkRegionalWatchdogURL || (env.RAIL_DATA_REFRESH_SECRET?.length ?? 0) < 32) {
    return { outcome: "failed" as const, failure: "configuration", httpStatus: null };
  }
  try {
    await denmarkOperation("publish", undefined, 3_000, async signal => {
      const response = await fetch(denmarkRegionalWatchdogURL, { method: "POST", redirect: "manual", signal,
        headers: { authorization: `Bearer ${env.RAIL_DATA_REFRESH_SECRET!}`, [denmarkWatchdogHeader]: "1" } });
      if (response.status !== 200) {
        await response.body?.cancel(); throw new DenmarkBusError("publish", "http", response.status);
      }
      if (response.headers.get("content-type")?.split(";")[0]?.trim().toLowerCase() !== "application/json") {
        await response.body?.cancel(); throw new DenmarkBusError("publish", "invalid-response");
      }
      const value = JSON.parse(new TextDecoder().decode(await denmarkResponseBytes(response, 2_048, "publish"))) as { accepted?: unknown; wakeScheduled?: unknown };
      if (value?.accepted !== true || value?.wakeScheduled !== true) throw new DenmarkBusError("publish", "invalid-response");
    });
    return { outcome: "ok" as const, httpStatus: 200 };
  } catch (error) {
    return { outcome: "failed" as const, failure: error instanceof DenmarkBusError ? error.code : "network",
      httpStatus: error instanceof DenmarkBusError ? error.httpStatus : null };
  }
}
