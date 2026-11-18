import type { LiveActivityPush } from "../domain/live-activity.js";

export function makeLiveActivityPayload(message: LiveActivityPush) {
  return {
    aps: {
      timestamp: message.timestamp,
      event: message.event,
      "content-state": message.content,
      "stale-date": Math.floor(message.content.validUntil),
      ...(message.event === "end" ? { "dismissal-date": message.timestamp } : {}),
      ...(message.alert === undefined ? {} : { alert: { title: message.alert.title, body: message.alert.body, sound: "default" } }),
    },
  };
}
