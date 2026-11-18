import { createHash, createHmac, timingSafeEqual } from "node:crypto";
import type { JourneyOptionSnapshot, JourneySearchRequest } from "./journey.js";
import type { CanonicalTripReference, ProviderSource } from "./snapshot.js";

export interface JourneyTrackingPayload {
  version: 1;
  expiresAt: string;
  fingerprint: string;
  originStationId: string;
  destinationStationId: string;
  departure: string;
  arrival: string;
  railSegments: Array<{
    segmentId: string;
    trip: CanonicalTripReference;
    boardingStationId: string;
    alightingStationId: string;
  }>;
}

interface JourneyCursorPayload {
  version: 1;
  expiresAt: string;
  providerCursor: string;
  criteriaHash: string;
}

type CursorCriteria = Omit<JourneySearchRequest, "cursor">;
type TokenDomain = "journey-tracking:v1:" | "journey-cursor:v1:";

const maximumTokenLength = 32 * 1_024;
const trackingLifetimeMilliseconds = 10 * 60_000;
const cursorLifetimeMilliseconds = 15 * 60_000;
const trackingDomain: TokenDomain = "journey-tracking:v1:";
const cursorDomain: TokenDomain = "journey-cursor:v1:";
const explicitInstant = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/u;
const serviceDate = /^\d{4}-\d{2}-\d{2}$/u;
const base64url = /^[A-Za-z0-9_-]+$/u;
const providerSources = new Set<ProviderSource>([
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

function fail(message: string): never {
  throw new Error(message);
}

function requireSecret(secret: string): void {
  if (typeof secret !== "string" || secret.length === 0) fail("Invalid journey token secret");
}

function validNow(now: Date): boolean {
  return now instanceof Date && Number.isFinite(now.getTime());
}

function expiration(now: Date, lifetimeMilliseconds: number, inputError: string): string {
  const milliseconds = now.getTime() + lifetimeMilliseconds;
  if (!Number.isFinite(milliseconds) || Math.abs(milliseconds) > 8_640_000_000_000_000) fail(inputError);
  return new Date(milliseconds).toISOString();
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  const actual = Object.keys(value);
  return actual.length === keys.length && actual.every((key) => keys.includes(key));
}

function isBoundedText(value: unknown, maximum: number): value is string {
  return typeof value === "string"
    && value.length > 0
    && value.length <= maximum
    && value.trim() === value;
}

function isExplicitInstant(value: unknown): value is string {
  return typeof value === "string"
    && value.length <= 64
    && explicitInstant.test(value)
    && Number.isFinite(Date.parse(value));
}

function isCanonicalExpiry(value: unknown): value is string {
  if (typeof value !== "string" || value.length > 32) return false;
  const milliseconds = Date.parse(value);
  return Number.isFinite(milliseconds) && new Date(milliseconds).toISOString() === value;
}

function isServiceDate(value: unknown): value is string {
  if (typeof value !== "string" || !serviceDate.test(value)) return false;
  const milliseconds = Date.parse(`${value}T00:00:00.000Z`);
  return Number.isFinite(milliseconds) && new Date(milliseconds).toISOString().slice(0, 10) === value;
}

function parseCanonicalTrip(id: unknown, date: unknown): CanonicalTripReference | null {
  if (!isBoundedText(id, 1_000) || !isServiceDate(date)) return null;
  const firstSeparator = id.indexOf(":");
  const secondSeparator = id.indexOf(":", firstSeparator + 1);
  if (firstSeparator < 1 || secondSeparator <= firstSeparator + 1) return null;
  const source = id.slice(firstSeparator + 1, secondSeparator);
  const nativeId = id.slice(secondSeparator + 1);
  if (!providerSources.has(source as ProviderSource) || !isBoundedText(nativeId, 500)) return null;
  if (source === "srbijavoz" && id.slice(0, firstSeparator) !== "rs") return null;
  return { id, source: source as ProviderSource, nativeId, serviceDate: date };
}

function canonicalTripIdentity(trip: CanonicalTripReference): string {
  return JSON.stringify([trip.source, trip.nativeId, trip.serviceDate]);
}

function trackingRailIdentity(segment: JourneyTrackingPayload["railSegments"][number]): string {
  return JSON.stringify([
    segment.segmentId,
    canonicalTripIdentity(segment.trip),
    segment.boardingStationId,
    segment.alightingStationId,
  ]);
}

function decodeBase64url(value: string): Buffer | null {
  if (!base64url.test(value) || value.length % 4 === 1) return null;
  const decoded = Buffer.from(value, "base64url");
  return decoded.toString("base64url") === value ? decoded : null;
}

function hmac(encodedPayload: string, secret: string, domain: TokenDomain): Buffer {
  return createHmac("sha256", secret).update(`${domain}${encodedPayload}`).digest();
}

function createSignedToken(
  payload: unknown,
  secret: string,
  domain: TokenDomain,
  inputError: string,
): string {
  const encoded = Buffer.from(JSON.stringify(payload), "utf8").toString("base64url");
  const signature = hmac(encoded, secret, domain).toString("base64url");
  const token = `${encoded}.${signature}`;
  if (token.length > maximumTokenLength) fail(inputError);
  return token;
}

function decodeSignedToken(
  token: string,
  secret: string,
  domain: TokenDomain,
  tokenError: string,
): unknown {
  if (typeof token !== "string" || token.length === 0 || token.length > maximumTokenLength) fail(tokenError);
  const separator = token.indexOf(".");
  if (separator < 1 || separator !== token.lastIndexOf(".") || separator === token.length - 1) fail(tokenError);
  const encoded = token.slice(0, separator);
  const suppliedText = token.slice(separator + 1);
  const payloadBytes = decodeBase64url(encoded);
  const supplied = decodeBase64url(suppliedText);
  if (payloadBytes === null || supplied === null || supplied.length !== 32) fail(tokenError);
  const expected = hmac(encoded, secret, domain);
  if (!timingSafeEqual(expected, supplied)) fail(tokenError);
  const payloadText = payloadBytes.toString("utf8");
  if (!Buffer.from(payloadText, "utf8").equals(payloadBytes)) fail(tokenError);
  try {
    return JSON.parse(payloadText) as unknown;
  } catch {
    return fail(tokenError);
  }
}

function trackingRailReferences(optionValue: Record<string, unknown>): {
  originStationId: string;
  destinationStationId: string;
  railSegments: JourneyTrackingPayload["railSegments"];
} {
  if (!Array.isArray(optionValue.segments) || optionValue.segments.length === 0) {
    return fail("Invalid journey tracking input");
  }
  const railLegs: Array<{
    id: string;
    tripId: string | null;
    serviceDate: string;
    boardingStationId: string;
    alightingStationId: string;
    isTrackable: boolean;
  }> = [];
  for (const candidate of optionValue.segments) {
    if (!isRecord(candidate) || !isBoundedText(candidate.id, 500)) fail("Invalid journey tracking input");
    if (candidate.kind === "walk") {
      if (!isRecord(candidate.walk) || candidate.rail !== null) fail("Invalid journey tracking input");
      continue;
    }
    if (candidate.kind !== "rail" || !isRecord(candidate.rail) || candidate.walk !== null) {
      fail("Invalid journey tracking input");
    }
    const rail = candidate.rail;
    const from = isRecord(rail.from) && isRecord(rail.from.place) ? rail.from.place : null;
    const to = isRecord(rail.to) && isRecord(rail.to.place) ? rail.to.place : null;
    if (from === null || to === null
      || !isBoundedText(from.id, 1_000)
      || !isBoundedText(to.id, 1_000)
      || !isServiceDate(rail.serviceDate)
      || (rail.tripId !== null && !isBoundedText(rail.tripId, 1_000))
      || typeof rail.isTrackable !== "boolean") {
      fail("Invalid journey tracking input");
    }
    if (rail.isTrackable && rail.tripId === null) fail("Invalid journey tracking input");
    railLegs.push({
      id: candidate.id,
      tripId: rail.tripId,
      serviceDate: rail.serviceDate,
      boardingStationId: from.id,
      alightingStationId: to.id,
      isTrackable: rail.isTrackable,
    });
  }
  const first = railLegs[0];
  const last = railLegs.at(-1);
  if (first === undefined || last === undefined) fail("Invalid journey tracking input");
  const seen = new Set<string>();
  const railSegments: JourneyTrackingPayload["railSegments"] = [];
  for (const leg of railLegs) {
    if (!leg.isTrackable || leg.tripId === null) continue;
    const trip = parseCanonicalTrip(leg.tripId, leg.serviceDate);
    if (trip === null) fail("Invalid journey tracking input");
    const reference = {
      segmentId: leg.id,
      trip,
      boardingStationId: leg.boardingStationId,
      alightingStationId: leg.alightingStationId,
    };
    const identity = trackingRailIdentity(reference);
    if (seen.has(identity)) continue;
    seen.add(identity);
    railSegments.push(reference);
  }
  return {
    originStationId: first.boardingStationId,
    destinationStationId: last.alightingStationId,
    railSegments,
  };
}

function trackingPayload(option: JourneyOptionSnapshot, expiresAt: string): JourneyTrackingPayload {
  if (!isRecord(option)
    || !isBoundedText(option.fingerprint, 500)
    || !isExplicitInstant(option.startTime)
    || !isExplicitInstant(option.endTime)
    || Date.parse(option.endTime) < Date.parse(option.startTime)) {
    return fail("Invalid journey tracking input");
  }
  const references = trackingRailReferences(option);
  return {
    version: 1,
    expiresAt,
    fingerprint: option.fingerprint,
    originStationId: references.originStationId,
    destinationStationId: references.destinationStationId,
    departure: option.startTime,
    arrival: option.endTime,
    railSegments: references.railSegments,
  };
}

function isCanonicalTrip(value: unknown): value is CanonicalTripReference {
  if (!isRecord(value) || !hasExactKeys(value, ["id", "source", "nativeId", "serviceDate"])) return false;
  const parsed = parseCanonicalTrip(value.id, value.serviceDate);
  return parsed !== null && value.source === parsed.source && value.nativeId === parsed.nativeId;
}

function isTrackingRailReference(value: unknown): value is JourneyTrackingPayload["railSegments"][number] {
  return isRecord(value)
    && hasExactKeys(value, ["segmentId", "trip", "boardingStationId", "alightingStationId"])
    && isBoundedText(value.segmentId, 500)
    && isCanonicalTrip(value.trip)
    && isBoundedText(value.boardingStationId, 1_000)
    && isBoundedText(value.alightingStationId, 1_000);
}

function isJourneyTrackingPayload(value: unknown): value is JourneyTrackingPayload {
  if (!isRecord(value)
    || !hasExactKeys(value, [
      "version",
      "expiresAt",
      "fingerprint",
      "originStationId",
      "destinationStationId",
      "departure",
      "arrival",
      "railSegments",
    ])
    || value.version !== 1
    || !isCanonicalExpiry(value.expiresAt)
    || !isBoundedText(value.fingerprint, 500)
    || !isBoundedText(value.originStationId, 1_000)
    || !isBoundedText(value.destinationStationId, 1_000)
    || !isExplicitInstant(value.departure)
    || !isExplicitInstant(value.arrival)
    || Date.parse(value.arrival) < Date.parse(value.departure)
    || !Array.isArray(value.railSegments)
    || !value.railSegments.every(isTrackingRailReference)) return false;
  const legIdentities = value.railSegments.map(trackingRailIdentity);
  return new Set(legIdentities).size === legIdentities.length;
}

function criteriaDigest(criteria: CursorCriteria): Buffer | null {
  if (!isRecord(criteria)
    || !isBoundedText(criteria.originId, 1_000)
    || !isBoundedText(criteria.destinationId, 1_000)
    || criteria.originId === criteria.destinationId
    || !isExplicitInstant(criteria.time)
    || typeof criteria.arriveBy !== "boolean"
    || !Number.isInteger(criteria.maxTransfers)
    || criteria.maxTransfers < 0
    || criteria.maxTransfers > 4) return null;
  const canonical = JSON.stringify({
    originId: criteria.originId,
    destinationId: criteria.destinationId,
    time: new Date(criteria.time).toISOString(),
    arriveBy: criteria.arriveBy,
    maxTransfers: criteria.maxTransfers,
  });
  return createHash("sha256").update(canonical).digest();
}

function isJourneyCursorPayload(value: unknown): value is JourneyCursorPayload {
  if (!isRecord(value)
    || !hasExactKeys(value, ["version", "expiresAt", "providerCursor", "criteriaHash"])
    || value.version !== 1
    || !isCanonicalExpiry(value.expiresAt)
    || typeof value.providerCursor !== "string"
    || value.providerCursor.length === 0
    || value.providerCursor.length > 16 * 1_024
    || typeof value.criteriaHash !== "string") return false;
  const digest = decodeBase64url(value.criteriaHash);
  return digest !== null && digest.length === 32;
}

export function createJourneyTrackingToken(
  option: JourneyOptionSnapshot,
  secret: string,
  now = new Date(),
): { token: string; expiresAt: string } {
  requireSecret(secret);
  if (!validNow(now)) fail("Invalid journey tracking input");
  const expiresAt = expiration(now, trackingLifetimeMilliseconds, "Invalid journey tracking input");
  const payload = trackingPayload(option, expiresAt);
  return {
    token: createSignedToken(payload, secret, trackingDomain, "Invalid journey tracking input"),
    expiresAt,
  };
}

export function resolveJourneyTrackingToken(
  token: string,
  secret: string,
  now = new Date(),
): JourneyTrackingPayload {
  requireSecret(secret);
  if (!validNow(now)) fail("Invalid journey tracking input");
  const value = decodeSignedToken(token, secret, trackingDomain, "Invalid journey tracking token");
  if (!isJourneyTrackingPayload(value)) fail("Invalid journey tracking token");
  if (Date.parse(value.expiresAt) <= now.getTime()) fail("Journey tracking token expired");
  return value;
}

export function createJourneyCursor(
  providerCursor: string,
  criteria: Omit<JourneySearchRequest, "cursor">,
  secret: string,
  now = new Date(),
): string {
  requireSecret(secret);
  const digest = criteriaDigest(criteria);
  if (!validNow(now)
    || typeof providerCursor !== "string"
    || providerCursor.length === 0
    || providerCursor.length > 16 * 1_024
    || digest === null) fail("Invalid journey cursor input");
  const payload: JourneyCursorPayload = {
    version: 1,
    expiresAt: expiration(now, cursorLifetimeMilliseconds, "Invalid journey cursor input"),
    providerCursor,
    criteriaHash: digest.toString("base64url"),
  };
  return createSignedToken(payload, secret, cursorDomain, "Invalid journey cursor input");
}

export function resolveJourneyCursor(
  token: string,
  criteria: Omit<JourneySearchRequest, "cursor">,
  secret: string,
  now = new Date(),
): string {
  requireSecret(secret);
  const digest = criteriaDigest(criteria);
  if (!validNow(now) || digest === null) fail("Invalid journey cursor input");
  const value = decodeSignedToken(token, secret, cursorDomain, "Invalid journey cursor");
  if (!isJourneyCursorPayload(value)) fail("Invalid journey cursor");
  if (Date.parse(value.expiresAt) <= now.getTime()) fail("Journey cursor expired");
  const suppliedDigest = decodeBase64url(value.criteriaHash);
  if (suppliedDigest === null || !timingSafeEqual(digest, suppliedDigest)) fail("Invalid journey cursor");
  return value.providerCursor;
}
