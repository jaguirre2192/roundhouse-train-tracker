import type { MaterialEvent } from "../domain/events.js";

export interface APNsPayload {
  aps: {
    alert: { title: string; body: string };
    sound: "default";
    "interruption-level": "time-sensitive";
    "thread-id": string;
  };
  tripID: string;
  eventID: string;
  eventKind: MaterialEvent["kind"];
  stopID?: string;
  eventServiceDate?: string;
  eventOldValue?: string;
  eventNewValue?: string;
  eventTiming?: "arrival" | "departure";
}

export function makeAPNsPayload(event: MaterialEvent): APNsPayload {
  return {
    aps: {
      alert: { title: event.title, body: event.body },
      sound: "default",
      "interruption-level": "time-sensitive",
      "thread-id": event.tripId,
    },
    tripID: event.tripId,
    eventID: event.fingerprint,
    eventKind: event.kind,
    ...(event.serviceDate === undefined ? {} : {
      eventServiceDate: event.serviceDate, eventNewValue: event.newValue,
      ...(event.oldValue === null ? {} : { eventOldValue: event.oldValue }),
      ...(event.timingEvent === undefined ? {} : { eventTiming: event.timingEvent }),
    }),
    ...(event.stopId === null ? {} : { stopID: event.stopId }),
  };
}
