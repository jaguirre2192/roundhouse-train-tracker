import type { DigitrafficTrain } from "./digitraffic-matching.js";

export interface DigitrafficPassengerCall { stationShortCode: string; from: number; to: number }
export interface DigitrafficPassengerMessage {
  id?: unknown;
  version?: unknown;
  startValidity?: unknown;
  endValidity?: unknown;
  trainNumber?: unknown;
  trainDepartureDate?: unknown;
  stations?: unknown;
  video?: { text?: Record<string, unknown> };
  audio?: { text?: Record<string, unknown> };
}

/** Only the public passenger-information API is eligible. Train tracking and
 * running-message records are operational telemetry, not passenger disruptions. */
export function digitrafficPassengerAlertIds(
  train: DigitrafficTrain, calls: DigitrafficPassengerCall[], messages: DigitrafficPassengerMessage[], now: number,
): string[] {
  return [...new Set(messages.flatMap(message => {
    if (typeof message !== "object" || message === null || typeof message.id !== "string" || !/^[\w.-]{1,256}$/u.test(message.id)
      || !Number.isSafeInteger(message.version) || Number(message.version) < 1
      || message.trainNumber !== train.trainNumber || message.trainDepartureDate !== train.departureDate
      || typeof message.startValidity !== "string" || typeof message.endValidity !== "string") return [];
    const from = Date.parse(message.startValidity), to = Date.parse(message.endValidity);
    if (!Number.isFinite(from) || !Number.isFinite(to) || from >= to || now < from || now >= to) return [];
    const hasText = [message.video?.text, message.audio?.text].some(text => text !== undefined && text !== null
      && typeof text === "object" && Object.values(text).some(value => typeof value === "string" && value.trim().length > 0));
    if (!hasText) return [];
    if (message.stations !== undefined && (!Array.isArray(message.stations)
      || !message.stations.every(value => typeof value === "string" && value.length > 0))) return [];
    const stations = message.stations as string[] | undefined;
    // Respect station restrictions and the call's own journey window. A notice
    // at another station or outside that call's time cannot affect this trip.
    const applicable = calls.some(call => (stations === undefined || stations.length === 0 || stations.includes(call.stationShortCode))
      && Number.isFinite(call.from) && Number.isFinite(call.to) && call.from < to && call.to >= from);
    return applicable ? [`digitraffic:passenger:${message.id}:v${message.version}`] : [];
  }))];
}
