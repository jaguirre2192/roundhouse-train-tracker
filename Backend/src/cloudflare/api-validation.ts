import {
  defaultPushPreferences,
  type CanonicalTripReference,
  type PushPreferences,
} from "../domain/snapshot.js";
import type { DeviceRegistration, SubscriptionInput } from "../worker/watcher-persistence.js";
import type { BoardReference, DiscoveryScope } from "../domain/discovery.js";
import type { SharedTripInput } from "../domain/share-links.js";

export class RequestValidationError extends Error {
  constructor(readonly issues: string[]) {
    super("Invalid request");
  }
}

type UnknownRecord = Record<string, unknown>;

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const tokenPattern = /^[a-fA-F0-9]{64,200}$/;
const datePattern = /^\d{4}-\d{2}-\d{2}$/;
const sources = new Set<CanonicalTripReference["source"]>([
  "amtraker",
  "transitous",
  "srbijavoz",
  "ekispert",
  "tdx",
  "chepe",
  "db",
  "sncf",
  "irail",
  "renfe",
]);

function record(value: unknown, name: string, issues: string[]): UnknownRecord {
  if (typeof value === "object" && value !== null && !Array.isArray(value)) return value as UnknownRecord;
  issues.push(`${name} must be an object`);
  return {};
}

function stringValue(
  value: unknown,
  name: string,
  issues: string[],
  maximumLength = 500,
): string {
  if (typeof value === "string" && value.length > 0 && value.length <= maximumLength) return value;
  issues.push(`${name} must be a non-empty string no longer than ${maximumLength} characters`);
  return "";
}

function booleanValue(value: unknown, fallback: boolean, name: string, issues: string[]): boolean {
  if (value === undefined) return fallback;
  if (typeof value === "boolean") return value;
  issues.push(`${name} must be a boolean`);
  return fallback;
}

function preferences(value: unknown, issues: string[]): PushPreferences {
  const input = value === undefined ? {} : record(value, "preferences", issues);
  const threshold = input.delayThresholdMinutes ?? defaultPushPreferences.delayThresholdMinutes;
  const validThreshold = typeof threshold === "number" && Number.isInteger(threshold) && threshold >= 0 && threshold <= 180;
  if (!validThreshold) issues.push("preferences.delayThresholdMinutes must be an integer from 0 through 180");
  return {
    delayThresholdMinutes: validThreshold ? threshold : defaultPushPreferences.delayThresholdMinutes,
    platformChanges: booleanValue(
      input.platformChanges,
      defaultPushPreferences.platformChanges,
      "preferences.platformChanges",
      issues,
    ),
    cancellations: booleanValue(
      input.cancellations,
      defaultPushPreferences.cancellations,
      "preferences.cancellations",
      issues,
    ),
    disruptions: booleanValue(
      input.disruptions,
      defaultPushPreferences.disruptions,
      "preferences.disruptions",
      issues,
    ),
  };
}

function finish<T>(value: T, issues: string[]): T {
  if (issues.length > 0) throw new RequestValidationError(issues);
  return value;
}

export function parseDeviceRegistration(value: unknown): DeviceRegistration {
  const issues: string[] = [];
  const input = record(value, "body", issues);
  const installationId = stringValue(input.installationId, "installationId", issues, 36);
  const token = stringValue(input.token, "token", issues, 200);
  const environment = input.environment;
  const platform = input.platform;

  if (!uuidPattern.test(installationId)) issues.push("installationId must be a UUID");
  if (!tokenPattern.test(token)) issues.push("token must be a hexadecimal APNs device token");
  if (environment !== "sandbox" && environment !== "production") {
    issues.push("environment must be sandbox or production");
  }
  if (platform !== "ios" && platform !== "macos") issues.push("platform must be ios or macos");

  return finish({
    installationId,
    token,
    environment: environment === "production" ? "production" : "sandbox",
    platform: platform === "macos" ? "macos" : "ios",
  }, issues);
}

export function parseSubscription(value: unknown): SubscriptionInput {
  const issues: string[] = [];
  const input = record(value, "body", issues);
  const tripInput = record(input.trip, "trip", issues);
  const installationId = stringValue(input.installationId, "installationId", issues, 36);
  const source = stringValue(tripInput.source, "trip.source", issues, 30);
  const serviceDate = stringValue(tripInput.serviceDate, "trip.serviceDate", issues, 10);
  const watchFrom = stringValue(input.watchFrom, "watchFrom", issues, 50);

  if (!uuidPattern.test(installationId)) issues.push("installationId must be a UUID");
  if (!sources.has(source as CanonicalTripReference["source"])) issues.push("trip.source is unsupported");
  if (!datePattern.test(serviceDate) || Number.isNaN(Date.parse(`${serviceDate}T00:00:00Z`))) {
    issues.push("trip.serviceDate must be an ISO date");
  }
  if (Number.isNaN(Date.parse(watchFrom))) issues.push("watchFrom must be an ISO timestamp");

  return finish({
    installationId,
    trip: {
      id: stringValue(tripInput.id, "trip.id", issues),
      source: source as CanonicalTripReference["source"],
      nativeId: stringValue(tripInput.nativeId, "trip.nativeId", issues),
      serviceDate,
    },
    boardingStationId: stringValue(input.boardingStationId, "boardingStationId", issues),
    alightingStationId: stringValue(input.alightingStationId, "alightingStationId", issues),
    watchFrom,
    preferences: preferences(input.preferences, issues),
  }, issues);
}

export function parseUnsubscribe(searchParams: URLSearchParams): { installationId: string; tripId: string } {
  const issues: string[] = [];
  const installationId = stringValue(searchParams.get("installationId"), "installationId", issues, 36);
  const tripId = stringValue(searchParams.get("tripId"), "tripId", issues);
  if (!uuidPattern.test(installationId)) issues.push("installationId must be a UUID");
  return finish({ installationId, tripId }, issues);
}

export function parseTripSnapshotRequest(searchParams: URLSearchParams): CanonicalTripReference {
  const issues: string[] = [];
  const source = stringValue(searchParams.get("source"), "source", issues, 30);
  const serviceDate = stringValue(searchParams.get("serviceDate"), "serviceDate", issues, 10);
  if (source !== "amtraker" && source !== "transitous" && source !== "srbijavoz" && source !== "ekispert" && source !== "tdx" && source !== "chepe") {
    issues.push("source must be amtraker, transitous, srbijavoz, ekispert, tdx, or chepe");
  }
  if (!datePattern.test(serviceDate) || Number.isNaN(Date.parse(`${serviceDate}T00:00:00Z`))) {
    issues.push("serviceDate must be an ISO date");
  }
  return finish({
    id: stringValue(searchParams.get("id"), "id", issues),
    source: source === "amtraker" || source === "srbijavoz" || source === "ekispert" || source === "tdx" || source === "chepe" ? source : "transitous",
    nativeId: stringValue(searchParams.get("nativeId"), "nativeId", issues),
    serviceDate,
  }, issues);
}

export function parseStationSearchRequest(searchParams: URLSearchParams): {
  scope: DiscoveryScope;
  query: string;
} {
  const issues: string[] = [];
  const scope = stringValue(searchParams.get("scope"), "scope", issues, 20);
  const query = stringValue(searchParams.get("query"), "query", issues, 100).trim();
  if (scope !== "us" && scope !== "international") issues.push("scope must be us or international");
  if (query.length < 2) issues.push("query must contain at least 2 characters");
  return finish({ scope: scope === "us" ? "us" : "international", query }, issues);
}

export function parseStationBoardRequest(searchParams: URLSearchParams): BoardReference {
  const issues: string[] = [];
  const source = stringValue(searchParams.get("source"), "source", issues, 30);
  const at = stringValue(searchParams.get("at"), "at", issues, 50);
  const timestamp = Date.parse(at);
  const direction = stringValue(searchParams.get("direction"), "direction", issues, 12);
  if (source !== "amtraker" && source !== "transitous" && source !== "srbijavoz" && source !== "ekispert" && source !== "tdx" && source !== "chepe") {
    issues.push("source must be amtraker, transitous, srbijavoz, ekispert, tdx, or chepe");
  }
  if (Number.isNaN(timestamp)) issues.push("at must be an ISO timestamp");
  if (direction !== "arrivals" && direction !== "departures") {
    issues.push("direction must be arrivals or departures");
  }
  return finish({
    stationId: stringValue(searchParams.get("stationId"), "stationId", issues),
    source: source === "amtraker" || source === "srbijavoz" || source === "ekispert" || source === "tdx" || source === "chepe" ? source : "transitous",
    nativeId: stringValue(searchParams.get("nativeId"), "nativeId", issues),
    // Canonical UTC seconds avoid upstream parsing differences for offsets and fractions.
    at: Number.isNaN(timestamp) ? at : new Date(timestamp).toISOString().replace(/\.\d{3}Z$/, "Z"),
    direction: direction === "arrivals" ? "arrivals" : "departures",
  }, issues);
}

export function parseSharedTrip(value: unknown): SharedTripInput {
  const issues: string[] = [];
  const input = record(value, "body", issues);
  const tripInput = record(input.trip, "trip", issues);
  const source = stringValue(tripInput.source, "trip.source", issues, 30);
  const serviceDate = stringValue(tripInput.serviceDate, "trip.serviceDate", issues, 10);
  const allowedSources = new Set(["amtraker", "transitous", "srbijavoz", "ekispert", "tdx", "chepe"]);
  if (!allowedSources.has(source)) issues.push("trip.source is not shareable");
  if (!datePattern.test(serviceDate) || Number.isNaN(Date.parse(`${serviceDate}T00:00:00Z`))) {
    issues.push("trip.serviceDate must be an ISO date");
  }
  const optionalIdentifier = (field: "boardingStationId" | "alightingStationId"): string | null | undefined => {
    const candidate = input[field];
    if (candidate === undefined || candidate === null) return candidate;
    return stringValue(candidate, field, issues);
  };
  const boardingStationId = optionalIdentifier("boardingStationId");
  const alightingStationId = optionalIdentifier("alightingStationId");
  return finish({
    trip: {
      id: stringValue(tripInput.id, "trip.id", issues),
      source: source as CanonicalTripReference["source"],
      nativeId: stringValue(tripInput.nativeId, "trip.nativeId", issues),
      serviceDate,
    },
    ...(boardingStationId === undefined ? {} : { boardingStationId }),
    ...(alightingStationId === undefined ? {} : { alightingStationId }),
  }, issues);
}
