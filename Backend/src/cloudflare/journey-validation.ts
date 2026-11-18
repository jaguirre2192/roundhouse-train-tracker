import type { JourneySearchRequest } from "../domain/journey.js";
import { RequestValidationError } from "./api-validation.js";

const explicitInstant = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(?:Z|[+-](\d{2}):(\d{2}))$/u;

export class JourneyServiceUnavailableError extends Error {
  constructor() {
    super("Journey search is unavailable");
    this.name = "JourneyServiceUnavailableError";
  }
}

function invalid(issue: string): never {
  throw new RequestValidationError([issue]);
}

function record(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return invalid("body must be an object");
  return value as Record<string, unknown>;
}

function exactKeys(value: Record<string, unknown>, keys: readonly string[]): void {
  const actual = Object.keys(value);
  if (actual.length !== keys.length || actual.some((key) => !keys.includes(key))) {
    invalid("body has unexpected fields");
  }
}

function placeId(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length < 1 || value.length > 1_000 || value.trim() !== value) {
    return invalid(`${field} must be a bounded place ID`);
  }
  return value;
}

function isExplicitInstant(value: unknown): value is string {
  if (typeof value !== "string" || value.length > 64 || !Number.isFinite(Date.parse(value))) return false;
  const match = explicitInstant.exec(value);
  if (match === null) return false;
  const [, year, month, day, hour, minute, second, offsetHour, offsetMinute] = match;
  const monthValue = Number(month);
  const dayValue = Number(day);
  const daysInMonth = new Date(Date.UTC(Number(year), monthValue, 0)).getUTCDate();
  return monthValue >= 1 && monthValue <= 12 && dayValue >= 1 && dayValue <= daysInMonth
    && Number(hour) <= 23 && Number(minute) <= 59 && Number(second) <= 59
    && (offsetHour === undefined || (Number(offsetHour) <= 23 && Number(offsetMinute) <= 59));
}

export function parseJourneyPlaceSearch(searchParams: URLSearchParams): { query: string; limit: number } {
  const keys = [...new Set(searchParams.keys())];
  if (keys.length !== 3 || keys.some((key) => !["q", "scope", "limit"].includes(key))
    || ["q", "scope", "limit"].some((key) => searchParams.getAll(key).length !== 1)) {
    return invalid("query must contain q, scope, and limit exactly once");
  }
  const query = searchParams.get("q")?.trim() ?? "";
  if (query.length < 2 || query.length > 100) invalid("q must contain 2 through 100 characters");
  if (searchParams.get("scope") !== "mainline") invalid("scope must be mainline");
  const limitText = searchParams.get("limit") ?? "";
  if (!/^\d+$/u.test(limitText)) invalid("limit must be an integer from 1 through 20");
  const limit = Number(limitText);
  if (!Number.isInteger(limit) || limit < 1 || limit > 20) invalid("limit must be an integer from 1 through 20");
  return { query, limit };
}

export function parseJourneySearch(value: unknown): JourneySearchRequest {
  const input = record(value);
  exactKeys(input, ["originId", "destinationId", "time", "arriveBy", "maxTransfers", "cursor"]);
  const originId = placeId(input.originId, "originId");
  const destinationId = placeId(input.destinationId, "destinationId");
  if (originId === destinationId) invalid("originId and destinationId must differ");
  if (!isExplicitInstant(input.time)) invalid("time must be an ISO-8601 timestamp with an explicit offset");
  if (typeof input.arriveBy !== "boolean") invalid("arriveBy must be a boolean");
  if (!Number.isInteger(input.maxTransfers) || (input.maxTransfers as number) < 0
    || (input.maxTransfers as number) > 4) invalid("maxTransfers must be an integer from 0 through 4");
  if (input.cursor !== null && (typeof input.cursor !== "string"
    || input.cursor.length < 1 || input.cursor.length > 8 * 1_024)) {
    invalid("cursor must be null or a bounded opaque value");
  }
  return {
    originId,
    destinationId,
    time: input.time,
    arriveBy: input.arriveBy,
    maxTransfers: input.maxTransfers as number,
    cursor: input.cursor,
  };
}

export function parseJourneyResolution(value: unknown): string[] {
  const input = record(value);
  exactKeys(input, ["trackingTokens"]);
  if (!Array.isArray(input.trackingTokens) || input.trackingTokens.length < 1 || input.trackingTokens.length > 2
    || input.trackingTokens.some((token) => typeof token !== "string" || token.length < 1 || token.length > 32 * 1_024)) {
    return invalid("trackingTokens must contain one or two bounded opaque values");
  }
  return input.trackingTokens as string[];
}
