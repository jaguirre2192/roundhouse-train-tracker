import { makeAPNsPayload } from "../apns/payload.js";
import {
  APNsError,
  pushCollapseId,
  pushExpirationSeconds,
  type PushMessage,
  type PushSender,
} from "../apns/transport.js";
import { APNsProviderToken } from "./apns-provider-token.js";

interface SenderConfig {
  mode: "live" | "dry-run";
  teamId: string;
  keyId: string;
  topics: Record<PushMessage["platform"], string>;
  privateKey: string;
}

export class CloudflareAPNsSender implements PushSender {
  private readonly providerToken: APNsProviderToken;

  constructor(private readonly config: SenderConfig) {
    this.providerToken = new APNsProviderToken(config);
  }

  async send(message: PushMessage): Promise<void> {
    const payload = makeAPNsPayload(message.event);
    if (this.config.mode === "dry-run") {
      console.info({ mode: "dry-run", tokenSuffix: message.token.slice(-8), payload });
      return;
    }

    const body = JSON.stringify(payload);
    if (new TextEncoder().encode(body).byteLength > 4_096) throw new APNsError(413, "PayloadTooLarge");
    const host = message.environment === "production"
      ? "https://api.push.apple.com"
      : "https://api.sandbox.push.apple.com";
    const response = await fetch(`${host}/3/device/${encodeURIComponent(message.token)}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${await this.providerToken.value()}`,
        "content-type": "application/json",
        "apns-topic": this.config.topics[message.platform],
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": String(pushExpirationSeconds(message)),
        "apns-collapse-id": pushCollapseId(message.event),
      },
      body,
    });
    if (response.status === 200) return;

    let reason = "Unknown";
    try {
      const parsed = await response.json() as { reason?: string };
      reason = parsed.reason ?? reason;
    } catch {
      // APNs may close an unsuccessful request without a JSON body.
    }
    throw new APNsError(response.status, reason);
  }
}
