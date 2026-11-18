import { createHmac, timingSafeEqual } from "node:crypto";
import type { CanonicalTripReference } from "./snapshot.js";

export interface SharedTripInput {
  trip: CanonicalTripReference;
  boardingStationId?: string | null;
  alightingStationId?: string | null;
}

export interface SharedTripPayload extends SharedTripInput {
  version: 1;
  expiresAt: string;
}

const shareLifetimeMilliseconds = 30 * 24 * 60 * 60_000;

function signature(payload: string, secret: string): Buffer {
  return createHmac("sha256", secret).update(payload).digest();
}

function encodedSignature(payload: string, secret: string): string {
  return signature(payload, secret).toString("base64url");
}

export function createSharedTripToken(
  input: SharedTripInput,
  secret: string,
  now = new Date(),
): { token: string; payload: SharedTripPayload } {
  const payload: SharedTripPayload = {
    version: 1,
    expiresAt: new Date(now.getTime() + shareLifetimeMilliseconds).toISOString(),
    trip: input.trip,
    ...(input.boardingStationId === undefined ? {} : { boardingStationId: input.boardingStationId }),
    ...(input.alightingStationId === undefined ? {} : { alightingStationId: input.alightingStationId }),
  };
  const encoded = Buffer.from(JSON.stringify(payload), "utf8").toString("base64url");
  return { token: `${encoded}.${encodedSignature(encoded, secret)}`, payload };
}

export function resolveSharedTripToken(token: string, secret: string, now = new Date()): SharedTripPayload {
  const [encoded, suppliedSignature, extra] = token.split(".");
  if (encoded === undefined || suppliedSignature === undefined || extra !== undefined) {
    throw new Error("Malformed shared trip token");
  }
  const expected = signature(encoded, secret);
  let supplied: Buffer;
  try {
    supplied = Buffer.from(suppliedSignature, "base64url");
  } catch {
    throw new Error("Malformed shared trip signature");
  }
  if (expected.length !== supplied.length || !timingSafeEqual(expected, supplied)) {
    throw new Error("Invalid shared trip signature");
  }
  let value: unknown;
  try {
    value = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8"));
  } catch {
    throw new Error("Malformed shared trip payload");
  }
  if (!isSharedTripPayload(value)) throw new Error("Unsupported shared trip payload");
  if (Date.parse(value.expiresAt) <= now.getTime()) throw new Error("Shared trip link has expired");
  return value;
}

function isSharedTripPayload(value: unknown): value is SharedTripPayload {
  if (typeof value !== "object" || value === null) return false;
  const payload = value as Partial<SharedTripPayload>;
  const trip = payload.trip as Partial<CanonicalTripReference> | undefined;
  return payload.version === 1
    && typeof payload.expiresAt === "string"
    && trip !== undefined
    && typeof trip.id === "string"
    && typeof trip.source === "string"
    && typeof trip.nativeId === "string"
    && typeof trip.serviceDate === "string";
}
