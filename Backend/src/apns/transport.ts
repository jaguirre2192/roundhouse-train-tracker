import type { MaterialEvent } from "../domain/events.js";

export interface PushMessage {
  token: string;
  environment: "sandbox" | "production";
  platform: "ios" | "macos";
  event: MaterialEvent;
  /// Epoch milliseconds when the outbox row was created. APNs expiration is
  /// anchored here, never at the delivery attempt, so retries cannot extend it.
  createdAt?: number;
}

export interface PushSender {
  send(message: PushMessage): Promise<void>;
}

// APNs reasons that will fail identically on every retry for this message.
const permanentReasons = new Set([
  "BadDeviceToken",
  "Unregistered",
  "DeviceTokenNotForTopic",
  "BadTopic",
  "TopicDisallowed",
  "MissingTopic",
  "PayloadTooLarge",
  "PayloadEmpty",
  "BadCollapseId",
  "BadExpirationDate",
  "BadPriority",
  "BadMessageId",
  "InvalidPushType",
  "BadCertificate",
  "BadCertificateEnvironment",
  // 403 provider-token failures other than ExpiredProviderToken need a
  // configuration change; by the time one ships, the alert is stale.
  "InvalidProviderToken",
  "MissingProviderToken",
  "Forbidden",
]);

export class APNsError extends Error {
  constructor(
    readonly status: number,
    readonly reason: string,
  ) {
    super(`APNs ${status}: ${reason}`);
  }

  get invalidatesDevice(): boolean {
    return this.status === 410 || this.reason === "BadDeviceToken" || this.reason === "Unregistered";
  }

  /// True when retrying the same message cannot succeed.
  get permanent(): boolean {
    return this.invalidatesDevice || this.status === 413 || permanentReasons.has(this.reason);
  }
}

/// Upper bound on delivery attempts for one outbox row, including the first.
export const maximumPushAttempts = 8;

/// Seconds an alert stays useful after the event was detected.
export function pushTimeToLiveSeconds(kind: MaterialEvent["kind"]): number {
  return kind === "platform-change" ? 15 * 60 : 60 * 60;
}

/// Oldest alert of any kind still worth delivering.
export const maximumPushAgeMilliseconds = 60 * 60_000;

/// Absolute APNs expiration (epoch seconds) anchored at the message's creation.
export function pushExpirationSeconds(message: PushMessage, now = Date.now()): number {
  const createdAt = message.createdAt ?? now;
  return Math.floor(createdAt / 1_000) + pushTimeToLiveSeconds(message.event.kind);
}

export function pushHasExpired(message: PushMessage, now = Date.now()): boolean {
  return message.createdAt !== undefined && pushExpirationSeconds(message, now) * 1_000 <= now;
}

/// One collapse identity per material event, shared by the Worker and Node senders.
export function pushCollapseId(event: MaterialEvent): string {
  return `${event.kind}:${event.fingerprint.slice(0, 32)}`;
}
