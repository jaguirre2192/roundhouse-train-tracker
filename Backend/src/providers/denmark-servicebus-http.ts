import { DenmarkServiceBusAuth } from "./denmark-servicebus-auth.js";
import { DenmarkBusError, denmarkOperation, denmarkResponseBytes } from "./denmark-servicebus-request.js";

export const maximumDenmarkMessageBytes = 1_024 * 1_024;
export interface DenmarkLockedMessage { bytes: Uint8Array; lock: string; lockExpiresAt?: number }
export interface DenmarkBusClient {
  receive(signal: AbortSignal): Promise<DenmarkLockedMessage | null>;
  settle(lock: string, action: "complete" | "abandon", signal?: AbortSignal): Promise<void>;
  close?(): Promise<void>;
}

/** Only the documented, bounded expiry field leaves the broker header. Unknown formats
 * omit expiry, so callers must publish that message alone rather than guess its lease. */
function lockExpiry(value: string | null): number | undefined {
  if (value === null || value.length > 8_192) return undefined;
  try {
    const properties = JSON.parse(value) as { LockedUntilUtc?: unknown } | null;
    const clock = properties?.LockedUntilUtc;
    if (typeof clock !== "string" || clock.length > 64) return undefined;
    const at = Date.parse(clock);
    if (!Number.isFinite(at) || at < 0) return undefined;
    const date = new Date(at);
    return [date.toUTCString(), date.toISOString(), date.toISOString().replace(".000Z", "Z")].includes(clock) ? at : undefined;
  } catch { return undefined; }
}

/** The issued AMQP URL identifies our dedicated topic subscription. HTTPS REST
 * adds subscriptions explicitly; no receive-and-delete operation exists here. */
export function denmarkSubscriptionEndpoint(value: string): URL {
  const url = new URL(value);
  const parts = url.pathname.split("/").filter(Boolean);
  if (url.protocol !== "amqps:" || url.hostname !== "sb-duvproddistribution.servicebus.windows.net"
    || url.port || url.username || url.password || url.search || url.hash || parts.length !== 2
    || parts.some((part) => !/^[A-Za-z0-9-]{1,128}$/u.test(part))) throw new Error("Invalid Denmark subscription configuration");
  return new URL(`https://${url.hostname}/${parts[0]}/subscriptions/${parts[1]}`);
}

export class DenmarkServiceBusHttp implements DenmarkBusClient {
  private readonly endpoint: URL;
  private readonly auth: DenmarkServiceBusAuth;
  constructor(subscription: string, clientID: string, clientSecret: string,
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init), now: () => number = () => Date.now()) {
    this.endpoint = denmarkSubscriptionEndpoint(subscription);
    this.auth = new DenmarkServiceBusAuth(clientID, clientSecret, fetcher, now);
  }

  async receive(parent: AbortSignal): Promise<DenmarkLockedMessage | null> {
    const token = await this.auth.token(parent); let lock: string | null = null;
    try {
      return await denmarkOperation("receive", parent, 8_000, async (signal) => {
        const response = await this.fetcher(`${this.endpoint.href}/messages/head?timeout=1`, {
          method: "POST", redirect: "manual", signal, headers: { authorization: `Bearer ${token}` },
        });
        if (response.status === 204) { await response.body?.cancel(); return null; }
        if (response.status !== 201) {
          if (response.status === 401) this.auth.invalidate();
          if (response.status === 405) {
            // Azure cannot receive an oversized AMQP message over its HTTP API.
            // Only that exact bounded broker explanation permits the fallback.
            const body = new TextDecoder().decode(await denmarkResponseBytes(response, 16_384, "receive"));
            if (/Cannot Receive Large Messages using ['"]HTTP['"] protocol/iu.test(body)) {
              throw new DenmarkBusError("receive", "requires-amqp", 405);
            }
          }
          await response.body?.cancel(); throw new DenmarkBusError("receive", "http", response.status);
        }
        const location = response.headers.get("location");
        if (location === null || !this.validLock(location)) {
          await response.body?.cancel(); throw new DenmarkBusError("receive", "invalid-lock");
        }
        lock = location;
        const bytes = await denmarkResponseBytes(response, maximumDenmarkMessageBytes, "receive");
        if (bytes.byteLength === 0) throw new DenmarkBusError("receive", "invalid-response");
        const lockExpiresAt = lockExpiry(response.headers.get("BrokerProperties"));
        return { bytes, lock: location, ...(lockExpiresAt === undefined ? {} : { lockExpiresAt }) };
      });
    } catch (error) {
      // Body failure still owns a lock. Return it promptly with an independent,
      // bounded cleanup attempt even when the receive deadline has expired.
      if (lock !== null) await this.settle(lock, "abandon").catch(() => undefined);
      throw error;
    }
  }

  async settle(lock: string, action: "complete" | "abandon", parent?: AbortSignal): Promise<void> {
    if (!this.validLock(lock)) throw new DenmarkBusError(action, "invalid-lock");
    await denmarkOperation(action, parent, action === "abandon" ? 3_000 : 5_000, async (signal) => {
      const token = await this.auth.token(signal);
      const response = await this.fetcher(lock, { method: action === "complete" ? "DELETE" : "PUT",
        redirect: "manual", signal, headers: { authorization: `Bearer ${token}` } });
      if (response.status === 401) this.auth.invalidate();
      await response.body?.cancel();
      if (response.status !== 200) throw new DenmarkBusError(action, "http", response.status);
    });
  }

  private validLock(value: string): boolean {
    try {
      const url = new URL(value), prefix = `${this.endpoint.pathname}/messages/`;
      return value.length <= 2_048 && url.origin === this.endpoint.origin && !url.username && !url.password && !url.hash
        && url.pathname.startsWith(prefix) && /^[^/]+\/[^/]+$/u.test(url.pathname.slice(prefix.length));
    } catch { return false; }
  }
}
