import { createHmac } from "node:crypto";
import { describe, expect, it } from "vitest";
import type {
  JourneyCallSnapshot,
  JourneyOptionSnapshot,
  JourneySegmentSnapshot,
  RailPlaceSnapshot,
} from "../src/domain/journey.js";
import {
  createJourneyCursor,
  createJourneyTrackingToken,
  resolveJourneyCursor,
  resolveJourneyTrackingToken,
} from "../src/domain/journey-tokens.js";

const secret = "a-long-random-journey-state-secret";
const now = new Date("2026-07-21T19:00:00.000Z");
const criteria = {
  originId: "rail:transitous:station:cGFyaXM",
  destinationId: "rail:transitous:station:YW1zdGVyZGFt",
  time: "2026-07-24T08:25:00+02:00",
  arriveBy: false,
  maxTransfers: 2,
};

function place(id: string): RailPlaceSnapshot {
  return {
    id,
    kind: "station",
    displayName: id,
    context: "Fixtureland",
    countryCode: "FX",
    timeZoneIdentifier: "Europe/Paris",
    location: { latitude: 48.8, longitude: 2.3 },
    eligibleModes: ["longDistanceRail"],
    attributions: ["Fixture Rail"],
  };
}

function call(id: string, time: string, endpoint: "from" | "to"): JourneyCallSnapshot {
  return {
    place: place(id),
    city: null,
    scheduledArrival: endpoint === "to" ? time : null,
    scheduledDeparture: endpoint === "from" ? time : null,
    expectedArrival: endpoint === "to" ? time : null,
    expectedDeparture: endpoint === "from" ? time : null,
    plannedPlatform: null,
    expectedPlatform: null,
    isCancelled: false,
  };
}

function railSegment(input: {
  id: string;
  tripId: string | null;
  serviceDate: string;
  from: string;
  to: string;
  departure: string;
  arrival: string;
  isTrackable?: boolean;
}): JourneySegmentSnapshot {
  return {
    id: input.id,
    kind: "rail",
    rail: {
      tripId: input.tripId,
      serviceDate: input.serviceDate,
      operatorName: "Fixture Rail",
      product: "Intercity",
      trainNumber: "42",
      trainName: "Fixture 42",
      from: call(input.from, input.departure, "from"),
      to: call(input.to, input.arrival, "to"),
      intermediateCalls: [],
      isCancelled: false,
      isRealtime: false,
      isTrackable: input.isTrackable ?? input.tripId !== null,
      untrackableReason: input.tripId === null ? "No stable train identity" : null,
    },
    walk: null,
  };
}

function option(segments?: JourneySegmentSnapshot[]): JourneyOptionSnapshot {
  const defaultSegments = [
    railSegment({
      id: "segment-1",
      tripId: "eu:transitous:trip-123",
      serviceDate: "2026-07-24",
      from: "station-paris",
      to: "station-brussels",
      departure: "2026-07-24T08:25:00+02:00",
      arrival: "2026-07-24T09:47:00+02:00",
    }),
    railSegment({
      id: "segment-2",
      tripId: "eu:transitous:trip-456",
      serviceDate: "2026-07-24",
      from: "station-brussels",
      to: "station-amsterdam",
      departure: "2026-07-24T09:53:00+02:00",
      arrival: "2026-07-24T12:14:00+02:00",
    }),
  ];
  return {
    id: "option-private-provider-id",
    fingerprint: "journey-v1-fingerprint",
    startTime: "2026-07-24T08:25:00+02:00",
    endTime: "2026-07-24T12:14:00+02:00",
    duration: 13_740,
    transferCount: 1,
    segments: segments ?? defaultSegments,
    badges: ["fastest"],
    trackability: { trackableRailSegments: 2, totalRailSegments: 2 },
    realtimeFreshness: "2026-07-21T18:59:30.000Z",
    attributions: ["Fixture Rail"],
    trackingToken: "previous-token",
  };
}

function encodedPayload(token: string): Record<string, unknown> {
  const encoded = token.split(".")[0]!;
  return JSON.parse(Buffer.from(encoded, "base64url").toString("utf8")) as Record<string, unknown>;
}

function signedToken(payload: unknown, domain: "journey-tracking:v1:" | "journey-cursor:v1:"): string {
  const encoded = Buffer.from(JSON.stringify(payload), "utf8").toString("base64url");
  const signature = createHmac("sha256", secret).update(`${domain}${encoded}`).digest("base64url");
  return `${encoded}.${signature}`;
}

function signedText(payload: string, domain: "journey-tracking:v1:" | "journey-cursor:v1:"): string {
  return signedBytes(Buffer.from(payload, "utf8"), domain);
}

function signedBytes(payload: Uint8Array, domain: "journey-tracking:v1:" | "journey-cursor:v1:"): string {
  const encoded = Buffer.from(payload).toString("base64url");
  const signature = createHmac("sha256", secret).update(`${domain}${encoded}`).digest("base64url");
  return `${encoded}.${signature}`;
}

describe("journey tracking tokens", () => {
  it("round trips a minimal ten-minute payload with ordered canonical trip references", () => {
    const created = createJourneyTrackingToken(option(), secret, now);

    expect(created.expiresAt).toBe("2026-07-21T19:10:00.000Z");
    expect(resolveJourneyTrackingToken(created.token, secret, now)).toEqual({
      version: 1,
      expiresAt: created.expiresAt,
      fingerprint: "journey-v1-fingerprint",
      originStationId: "station-paris",
      destinationStationId: "station-amsterdam",
      departure: "2026-07-24T08:25:00+02:00",
      arrival: "2026-07-24T12:14:00+02:00",
      railSegments: [
        {
          segmentId: "segment-1",
          trip: {
            id: "eu:transitous:trip-123",
            source: "transitous",
            nativeId: "trip-123",
            serviceDate: "2026-07-24",
          },
          boardingStationId: "station-paris",
          alightingStationId: "station-brussels",
        },
        {
          segmentId: "segment-2",
          trip: {
            id: "eu:transitous:trip-456",
            source: "transitous",
            nativeId: "trip-456",
            serviceDate: "2026-07-24",
          },
          boardingStationId: "station-brussels",
          alightingStationId: "station-amsterdam",
        },
      ],
    });

    const payload = JSON.stringify(encodedPayload(created.token));
    expect(payload).not.toContain("option-private-provider-id");
    expect(payload).not.toContain("Fixture Rail");
    expect(payload).not.toContain("previous-token");
    expect(Object.keys(encodedPayload(created.token))).toEqual([
      "version",
      "expiresAt",
      "fingerprint",
      "originStationId",
      "destinationStationId",
      "departure",
      "arrival",
      "railSegments",
    ]);
  });

  it("expires at exactly ten minutes but remains valid immediately before the boundary", () => {
    const created = createJourneyTrackingToken(option(), secret, now);

    expect(() => resolveJourneyTrackingToken(
      created.token,
      secret,
      new Date("2026-07-21T19:09:59.999Z"),
    )).not.toThrow();
    expect(() => resolveJourneyTrackingToken(
      created.token,
      secret,
      new Date("2026-07-21T19:10:00.000Z"),
    )).toThrow("Journey tracking token expired");
  });

  it("preserves distinct segment IDs sharing one dated trip in signed order", () => {
    const first = railSegment({
      id: "segment-first",
      tripId: "eu:transitous:trip-123",
      serviceDate: "2026-07-24",
      from: "station-paris",
      to: "station-brussels",
      departure: "2026-07-24T08:25:00+02:00",
      arrival: "2026-07-24T09:47:00+02:00",
    });
    const duplicate = railSegment({
      id: "segment-duplicate",
      tripId: "eu:transitous:trip-123",
      serviceDate: "2026-07-24",
      from: "station-paris-alias",
      to: "station-brussels-alias",
      departure: "2026-07-24T08:25:00+02:00",
      arrival: "2026-07-24T09:47:00+02:00",
    });
    const second = railSegment({
      id: "segment-second",
      tripId: "eu:transitous:trip-456",
      serviceDate: "2026-07-24",
      from: "station-brussels",
      to: "station-amsterdam",
      departure: "2026-07-24T09:53:00+02:00",
      arrival: "2026-07-24T12:14:00+02:00",
    });
    const payload = resolveJourneyTrackingToken(
      createJourneyTrackingToken(option([first, duplicate, second]), secret, now).token,
      secret,
      now,
    );

    expect(payload.railSegments.map((segment) => ({
      segmentId: segment.segmentId,
      boardingStationId: segment.boardingStationId,
      alightingStationId: segment.alightingStationId,
    }))).toEqual([
      {
        segmentId: "segment-first",
        boardingStationId: "station-paris",
        alightingStationId: "station-brussels",
      },
      {
        segmentId: "segment-duplicate",
        boardingStationId: "station-paris-alias",
        alightingStationId: "station-brussels-alias",
      },
      {
        segmentId: "segment-second",
        boardingStationId: "station-brussels",
        alightingStationId: "station-amsterdam",
      },
    ]);
  });

  it("collapses exact duplicate legs but preserves dates and rejects exact signed duplicates", () => {
    const firstDate = railSegment({
      id: "segment-first-date",
      tripId: "eu:transitous:repeating-trip-123",
      serviceDate: "2026-07-24",
      from: "station-paris",
      to: "station-brussels",
      departure: "2026-07-24T22:25:00+02:00",
      arrival: "2026-07-24T23:47:00+02:00",
    });
    const secondDate = railSegment({
      id: "segment-second-date",
      tripId: "eu:transitous:repeating-trip-123",
      serviceDate: "2026-07-25",
      from: "station-brussels",
      to: "station-amsterdam",
      departure: "2026-07-25T09:53:00+02:00",
      arrival: "2026-07-25T12:14:00+02:00",
    });
    const selected = {
      ...option([firstDate, firstDate, secondDate]),
      startTime: "2026-07-24T22:25:00+02:00",
      endTime: "2026-07-25T12:14:00+02:00",
    };
    const created = createJourneyTrackingToken(selected, secret, now);
    const payload = resolveJourneyTrackingToken(created.token, secret, now);

    expect(payload.railSegments.map((segment) => segment.trip.serviceDate)).toEqual([
      "2026-07-24",
      "2026-07-25",
    ]);
    expect(payload.railSegments.map((segment) => segment.segmentId)).toEqual([
      "segment-first-date",
      "segment-second-date",
    ]);

    const firstReference = payload.railSegments[0]!;
    const duplicateSignedPayload = {
      ...payload,
      railSegments: [...payload.railSegments, firstReference],
    };
    expect(() => resolveJourneyTrackingToken(
      signedToken(duplicateSignedPayload, "journey-tracking:v1:"),
      secret,
      now,
    )).toThrow("Invalid journey tracking token");
  });

  it("rejects a correctly signed payload containing invalid raw UTF-8 bytes", () => {
    const token = createJourneyTrackingToken(option(), secret, now).token;
    const encoded = token.split(".")[0]!;
    const bytes = Buffer.from(encoded, "base64url");
    const fingerprintOffset = bytes.indexOf(Buffer.from("journey-v1-fingerprint", "utf8"));
    expect(fingerprintOffset).toBeGreaterThanOrEqual(0);
    bytes[fingerprintOffset] = 0x80;

    expect(() => resolveJourneyTrackingToken(
      signedBytes(bytes, "journey-tracking:v1:"),
      secret,
      now,
    )).toThrow("Invalid journey tracking token");
  });

  it("rejects tampering, malformed encodings, malformed payloads, and unsupported versions", () => {
    const token = createJourneyTrackingToken(option(), secret, now).token;
    const [encoded, signature] = token.split(".") as [string, string];
    const noncanonicalPayload = `${encoded}=`;
    const noncanonicalSignature = `${signature}=`;

    expect(() => resolveJourneyTrackingToken(`${encoded.slice(0, -1)}A.${signature}`, secret, now))
      .toThrow("Invalid journey tracking token");
    expect(() => resolveJourneyTrackingToken(`${noncanonicalPayload}.${signature}`, secret, now))
      .toThrow("Invalid journey tracking token");
    expect(() => resolveJourneyTrackingToken(`${encoded}.${noncanonicalSignature}`, secret, now))
      .toThrow("Invalid journey tracking token");
    expect(() => resolveJourneyTrackingToken("not-base64!.also-not-base64!", secret, now))
      .toThrow("Invalid journey tracking token");
    expect(() => resolveJourneyTrackingToken(signedText("{", "journey-tracking:v1:"), secret, now))
      .toThrow("Invalid journey tracking token");
    expect(() => resolveJourneyTrackingToken(signedToken("not-an-object", "journey-tracking:v1:"), secret, now))
      .toThrow("Invalid journey tracking token");
    expect(() => resolveJourneyTrackingToken(signedToken({ version: 2 }, "journey-tracking:v1:"), secret, now))
      .toThrow("Invalid journey tracking token");
    expect(() => resolveJourneyTrackingToken(signedToken({ version: 1, secret }, "journey-tracking:v1:"), secret, now))
      .toThrow("Invalid journey tracking token");
  });

  it("rejects tokens over 32 KiB before decoding and keeps failures bounded", () => {
    const oversized = `${"A".repeat(32 * 1_024)}.signature`;
    let thrown: unknown;

    try {
      resolveJourneyTrackingToken(oversized, secret, now);
    } catch (error) {
      thrown = error;
    }

    expect(thrown).toBeInstanceOf(Error);
    expect((thrown as Error).message).toBe("Invalid journey tracking token");
    expect((thrown as Error).message.length).toBeLessThan(100);
    expect((thrown as Error).message).not.toContain(secret);
    expect((thrown as Error).message).not.toContain(oversized.slice(0, 100));
  });

  it("rejects invalid creation inputs and secrets without emitting token material", () => {
    expect(() => createJourneyTrackingToken(option(), "", now))
      .toThrow("Invalid journey token secret");
    expect(() => createJourneyTrackingToken({ ...option(), fingerprint: "" }, secret, now))
      .toThrow("Invalid journey tracking input");
    expect(() => createJourneyTrackingToken(option(), secret, new Date("invalid")))
      .toThrow("Invalid journey tracking input");
    expect(() => createJourneyTrackingToken(option(), secret, new Date(8_640_000_000_000_000)))
      .toThrow("Invalid journey tracking input");
  });
});

describe("journey cursors", () => {
  it("round trips an opaque provider cursor for fifteen minutes with canonical criteria binding", () => {
    const providerCursor = " opaque upstream cursor +/== with spaces ";
    const token = createJourneyCursor(providerCursor, criteria, secret, now);
    const reorderedCriteria = {
      maxTransfers: criteria.maxTransfers,
      arriveBy: criteria.arriveBy,
      time: criteria.time,
      destinationId: criteria.destinationId,
      originId: criteria.originId,
    };

    expect(resolveJourneyCursor(token, reorderedCriteria, secret, now)).toBe(providerCursor);
    expect(encodedPayload(token)).toMatchObject({
      version: 1,
      expiresAt: "2026-07-21T19:15:00.000Z",
      providerCursor,
    });
    expect(encodedPayload(token)).not.toHaveProperty("criteria");
    expect(encodedPayload(token)).not.toHaveProperty("originId");
    expect(encodedPayload(token)).not.toHaveProperty("destinationId");
  });

  it("expires at exactly fifteen minutes and rejects criteria mismatches", () => {
    const token = createJourneyCursor("provider-cursor", criteria, secret, now);

    expect(() => resolveJourneyCursor(
      token,
      criteria,
      secret,
      new Date("2026-07-21T19:14:59.999Z"),
    )).not.toThrow();
    expect(() => resolveJourneyCursor(
      token,
      criteria,
      secret,
      new Date("2026-07-21T19:15:00.000Z"),
    )).toThrow("Journey cursor expired");
    expect(() => resolveJourneyCursor(
      token,
      { ...criteria, destinationId: "different-destination" },
      secret,
      now,
    )).toThrow("Invalid journey cursor");
  });

  it("rejects tampering, malformed base64, malformed JSON, and oversized cursors", () => {
    const token = createJourneyCursor("provider-cursor", criteria, secret, now);
    const [encoded, signature] = token.split(".") as [string, string];

    expect(() => resolveJourneyCursor(`${encoded.slice(0, -1)}A.${signature}`, criteria, secret, now))
      .toThrow("Invalid journey cursor");
    expect(() => resolveJourneyCursor(`${encoded}=.${signature}`, criteria, secret, now))
      .toThrow("Invalid journey cursor");
    expect(() => resolveJourneyCursor(signedText("{", "journey-cursor:v1:"), criteria, secret, now))
      .toThrow("Invalid journey cursor");
    expect(() => resolveJourneyCursor(signedToken("not-an-object", "journey-cursor:v1:"), criteria, secret, now))
      .toThrow("Invalid journey cursor");
    expect(() => resolveJourneyCursor(signedToken({ version: 2 }, "journey-cursor:v1:"), criteria, secret, now))
      .toThrow("Invalid journey cursor");
    expect(() => resolveJourneyCursor(`${"A".repeat(32 * 1_024)}.signature`, criteria, secret, now))
      .toThrow("Invalid journey cursor");
  });

  it("separates cursor and tracking signature domains", () => {
    const token = createJourneyCursor("provider-cursor", criteria, secret, now);
    const [encoded] = token.split(".") as [string, string];
    const trackingSignature = createHmac("sha256", secret)
      .update(`journey-tracking:v1:${encoded}`)
      .digest("base64url");

    expect(() => resolveJourneyCursor(`${encoded}.${trackingSignature}`, criteria, secret, now))
      .toThrow("Invalid journey cursor");
  });

  it("rejects invalid cursor inputs, criteria, and secrets", () => {
    expect(() => createJourneyCursor("", criteria, secret, now))
      .toThrow("Invalid journey cursor input");
    expect(() => createJourneyCursor("provider-cursor", { ...criteria, maxTransfers: -1 }, secret, now))
      .toThrow("Invalid journey cursor input");
    expect(() => createJourneyCursor("provider-cursor", criteria, "", now))
      .toThrow("Invalid journey token secret");
    expect(() => createJourneyCursor(
      "provider-cursor",
      criteria,
      secret,
      new Date(8_640_000_000_000_000),
    )).toThrow("Invalid journey cursor input");
    expect(() => resolveJourneyCursor("token", criteria, "", now))
      .toThrow("Invalid journey token secret");
  });
});
