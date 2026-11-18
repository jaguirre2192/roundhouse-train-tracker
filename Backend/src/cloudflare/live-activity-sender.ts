import { makeLiveActivityPayload } from "../apns/live-activity-payload.js";
import { APNsError } from "../apns/transport.js";
import type { LiveActivityPush, LiveActivitySender } from "../domain/live-activity.js";
import { APNsProviderToken } from "./apns-provider-token.js";

interface Config {
  mode: "live" | "dry-run";
  teamId: string;
  keyId: string;
  privateKey: string;
  bundleId: string;
}

export class CloudflareLiveActivitySender implements LiveActivitySender {
  private readonly providerToken: APNsProviderToken;
  constructor(private readonly config: Config) { this.providerToken = new APNsProviderToken(config); }

  async send(message: LiveActivityPush): Promise<void> {
    const body = JSON.stringify(makeLiveActivityPayload(message));
    if (new TextEncoder().encode(body).byteLength > 4_096) throw new Error("Live Activity payload exceeds 4 KB");
    if (this.config.mode === "dry-run") return;
    const expiration = message.alert === undefined ? message.expiresAt / 1_000
      : Math.min(message.expiresAt / 1_000, message.content.validUntil, message.content.eventTime ?? 0);
    const host = message.environment === "production" ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com";
    const response = await fetch(`${host}/3/device/${encodeURIComponent(message.token)}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${await this.providerToken.value()}`,
        "content-type": "application/json",
        "apns-topic": `${this.config.bundleId}.push-type.liveactivity`,
        "apns-push-type": "liveactivity",
        // Alerting updates must arrive now; routine refreshes stay low priority to save the device's budget.
        "apns-priority": message.alert === undefined ? "5" : "10",
        "apns-expiration": String(Math.floor(expiration)),
        "apns-collapse-id": message.activityId.slice(0, 64),
      },
      signal: AbortSignal.timeout(15_000),
      body,
    });
    if (response.status === 200) return;
    let reason = "Unknown";
    try { reason = (await response.json() as { reason?: string }).reason ?? reason; } catch { /* Empty APNs errors. */ }
    throw new APNsError(response.status, reason);
  }
}
