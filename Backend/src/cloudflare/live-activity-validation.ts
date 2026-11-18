import type { LiveActivityContentState, LiveActivityRegistration } from "../domain/live-activity.js";
import { parseTripSnapshotRequest, RequestValidationError } from "./api-validation.js";

const invalid = (field: string): never => { throw new RequestValidationError([`${field} is invalid`]); };
const object = (value: unknown): Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown> : invalid("body");
function string(value: unknown, field: string, limit = 256): string {
  return typeof value === "string" && value.length > 0 && value.length <= limit ? value : invalid(field);
}
function number(value: unknown, field: string): number {
  return typeof value === "number" && Number.isFinite(value) ? value : invalid(field);
}
function integer(value: unknown, field: string, maximum: number): number {
  const parsed = number(value, field);
  return Number.isSafeInteger(parsed) && parsed >= 0 && parsed <= maximum ? parsed : invalid(field);
}
function choice<T extends string>(value: unknown, field: string, choices: readonly T[]): T {
  return choices.includes(value as T) ? value as T : invalid(field);
}
function boolean(value: unknown, field: string): boolean {
  return typeof value === "boolean" ? value : invalid(field);
}
function nullableNumber(value: unknown, field: string): number | null {
  return value == null ? null : number(value, field);
}
function timeZone(value: unknown): string | null {
  if (value == null) return null;
  const zone = string(value, "timeZoneIdentifier", 100);
  try { new Intl.DateTimeFormat("en", { timeZone: zone }); } catch { invalid("timeZoneIdentifier"); }
  return zone;
}

export function parseLiveActivityContent(value: unknown): LiveActivityContentState {
  const input = object(value);
  if (input.schemaVersion !== 1) invalid("schemaVersion");
  return {
    schemaVersion: 1,
    phase: choice(input.phase, "phase", ["upcoming", "departureSoon", "underway", "ended", "cancelled", "unavailable"]),
    focusName: string(input.focusName, "focusName", 160),
    eventTime: nullableNumber(input.eventTime, "eventTime"),
    timeZoneIdentifier: timeZone(input.timeZoneIdentifier),
    timingBasis: choice(input.timingBasis, "timingBasis", ["scheduled", "estimated", "unavailable"]),
    platform: input.platform == null ? null : string(input.platform, "platform", 40),
    platformBasis: choice(input.platformBasis, "platformBasis", ["scheduled", "reported", "predicted", "unavailable"]),
    platformChanged: boolean(input.platformChanged, "platformChanged"),
    delayMinutes: nullableNumber(input.delayMinutes, "delayMinutes"),
    checkedAt: nullableNumber(input.checkedAt, "checkedAt"),
    validUntil: number(input.validUntil, "validUntil"),
    isStopCancelled: boolean(input.isStopCancelled, "isStopCancelled"),
    ...(input.platformKind == null ? {} : { platformKind: choice(input.platformKind, "platformKind", ["track", "platform"]) }),
    ...(input.platformSource == null || input.platform == null
      ? {} : { platformSource: string(input.platformSource, "platformSource", 32) }),
    ...(input.boardingPlatformSequence != null && (input.phase === "upcoming" || input.phase === "departureSoon") && input.platformBasis === "reported"
      && input.platform != null && input.eventTime != null
      ? { boardingPlatformSequence: integer(input.boardingPlatformSequence, "boardingPlatformSequence", 2_147_483_647) } : {}),
  };
}

export function parseLiveActivityIdentity(installation: unknown, activity: unknown) {
  const installationId = string(installation, "installationId", 36).toLowerCase();
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(installationId)) invalid("installationId");
  const activityId = string(activity, "activityId", 128);
  if (!/^[A-Za-z0-9_.:-]+$/u.test(activityId)) invalid("activityId");
  return { installationId, activityId };
}

export function parseLiveActivityRegistration(value: unknown): LiveActivityRegistration {
  const input = object(value);
  if (input.schemaVersion !== 1) invalid("schemaVersion");
  const identity = parseLiveActivityIdentity(input.installationId, input.activityId);
  const token = string(input.token, "token", 1_024).toLowerCase();
  if (!/^(?:[a-f0-9]{2}){16,512}$/u.test(token)) invalid("token");
  const tokenGeneration = integer(input.tokenGeneration, "tokenGeneration", 2_147_483_647);
  if (tokenGeneration < 1) invalid("tokenGeneration");
  const tripInput = object(input.trip);
  const trip = parseTripSnapshotRequest(new URLSearchParams({
    id: string(tripInput.id, "trip.id"), source: string(tripInput.source, "trip.source"),
    nativeId: string(tripInput.nativeId, "trip.nativeId"), serviceDate: string(tripInput.serviceDate, "trip.serviceDate"),
  }));
  const boardingStopSequence = integer(input.boardingStopSequence, "boardingStopSequence", 100_000);
  const alightingStopSequence = integer(input.alightingStopSequence, "alightingStopSequence", 100_000);
  if (alightingStopSequence <= boardingStopSequence) invalid("stop sequences");
  const startedAt = string(input.startedAt, "startedAt", 40);
  if (!Number.isFinite(Date.parse(startedAt))) invalid("startedAt");
  const stationTimeZones: Record<string, string> = {};
  if (input.stationTimeZones !== undefined) {
    const entries = Object.entries(object(input.stationTimeZones));
    if (entries.length > 100) invalid("stationTimeZones");
    for (const [id, zone] of entries) {
      if (["__proto__", "constructor", "prototype"].includes(id)) invalid("stationTimeZones");
      stationTimeZones[string(id, "station ID")] = timeZone(zone) ?? invalid("stationTimeZones");
    }
  }
  return {
    schemaVersion: 1, ...identity, token, tokenGeneration,
    environment: choice(input.environment, "environment", ["sandbox", "production"]),
    trip,
    boardingStationId: string(input.boardingStationId, "boardingStationId"),
    alightingStationId: string(input.alightingStationId, "alightingStationId"),
    boardingStopSequence, alightingStopSequence, stationTimeZones,
    ...(input.isRiding == null ? {} : { isRiding: boolean(input.isRiding, "isRiding") }),
    startedAt: new Date(startedAt).toISOString(),
    initialContentState: parseLiveActivityContent(input.initialContentState),
  };
}
