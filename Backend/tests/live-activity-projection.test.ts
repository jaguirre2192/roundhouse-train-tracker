import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { projectLiveActivity, type LiveActivityProjection } from "../src/domain/live-activity-projection.js";
import type { StopSnapshot, TripSnapshot } from "../src/domain/snapshot.js";
import { makeLiveActivityPayload } from "../src/apns/live-activity-payload.js";
import { liveActivityAlert } from "../src/domain/live-activity.js";
import type { LiveActivityContentState } from "../src/domain/live-activity.js";

interface FixtureStop {
  stationID: string; stationName: string; sequence: number;
  scheduledArrival?: number; scheduledDeparture?: number; expectedArrival?: number; expectedDeparture?: number;
  plannedPlatform?: string; expectedPlatform?: string; isCancelled: boolean; isPassed: boolean;
}
interface Fixture {
  name: string;
  input: { referenceDate: number; lastSuccessfulCheck: number | null; refreshFailed: boolean;
    boardingStationID: string | null; alightingStationID: string | null;
    stationTimeZones: Record<string, string>; trip: { id: string; source: string; stops: FixtureStop[] } };
  expected: LiveActivityProjection;
}
const fixtures = JSON.parse(readFileSync(new URL(
  "../../Packages/TrainTrackerCore/Tests/TrainTrackerCoreTests/Fixtures/LiveActivity/projection-cases.json", import.meta.url,
), "utf8")) as { cases: Fixture[] };

function snapshot(fixture: Fixture): TripSnapshot {
  const iso = (value: number | undefined) => value == null ? null : new Date(value * 1_000).toISOString();
  const stops: StopSnapshot[] = fixture.input.trip.stops.map((stop) => ({
    stationId: stop.stationID, stationName: stop.stationName, sequence: stop.sequence, countryCode: "GB",
    latitude: null, longitude: null, scheduledArrival: iso(stop.scheduledArrival), scheduledDeparture: iso(stop.scheduledDeparture),
    expectedArrival: iso(stop.expectedArrival), expectedDeparture: iso(stop.expectedDeparture),
    plannedPlatform: stop.plannedPlatform ?? null, expectedPlatform: stop.expectedPlatform ?? null,
    platformSource: null, platformObservedAt: null, cancelled: stop.isCancelled, passed: stop.isPassed,
  }));
  return { id: fixture.input.trip.id, source: "transitous", nativeId: "test", serviceDate: "2027-01-15",
    operatorName: "Test", product: "IC", headsign: "Destination", fetchedAt: iso(fixture.input.referenceDate)!, stops, alertIds: [] };
}

describe("Live Activity projection", () => {
  for (const fixture of fixtures.cases) it(`matches Swift fixture: ${fixture.name}`, () => {
    expect(projectLiveActivity({ ...fixture.input, trip: snapshot(fixture),
      boardingStationId: fixture.input.boardingStationID, alightingStationId: fixture.input.alightingStationID,
    })).toEqual(fixture.expected);
  });

  it("creates a silent ActivityKit payload with exact schema names and end dismissal", () => {
    const content: LiveActivityContentState = fixtures.cases[0]!.expected.state;
    const payload = makeLiveActivityPayload({ activityId: "activity", token: "a".repeat(64), tokenGeneration: 1,
      environment: "sandbox", revision: 1, timestamp: 1_800_000_000, event: "end", content, expiresAt: 1_800_000_900_000 });
    expect(payload.aps["content-state"]).toEqual(content);
    expect(payload.aps["dismissal-date"]).toBe(1_800_000_000);
    expect(payload.aps).not.toHaveProperty("alert");
    expect(new TextEncoder().encode(JSON.stringify(payload)).length).toBeLessThan(4_096);
  });

  it("marks the reported boarding assignment only for a selected unpassed departure call", () => {
    const fixture = fixtures.cases.find((row) => row.name === "departure-soon-at-exact-half-hour-boundary")!;
    const trip = snapshot(fixture);
    const first = trip.stops[0]!;
    const report = { ...first, expectedPlatform: "8", platformObservedAt: new Date(fixture.input.referenceDate * 1_000).toISOString() };
    const project = (stop: StopSnapshot) => projectLiveActivity({ ...fixture.input,
      trip: { ...trip, stops: [stop, ...trip.stops.slice(1)] } }).state;
    expect(project(report).boardingPlatformSequence).toBe(first.sequence);
    expect(project(first).boardingPlatformSequence).toBeUndefined();
    expect(project({ ...report, passed: true, passageObservedAt: report.platformObservedAt }).boardingPlatformSequence).toBeUndefined();
    expect(project({ ...report, platformObservedAt: new Date((fixture.input.referenceDate - 840) * 1_000).toISOString() })
      .validUntil).toBeLessThan(fixture.input.referenceDate);
  });

  it("alerts only for a new or changed reported boarding track", () => {
    const now = 1_800_000_000;
    const selection = { boardingStopSequence: 1 };
    const base: LiveActivityContentState = { ...fixtures.cases[0]!.expected.state, phase: "departureSoon",
      focusName: "New York Penn", checkedAt: now, validUntil: now + 300, eventTime: now + 900,
      platform: null, platformBasis: "unavailable", platformKind: "track", isStopCancelled: false };
    const assigned = { ...base, boardingPlatformSequence: 1, platform: "7", platformBasis: "reported" as const };
    const alert = (old: LiveActivityContentState, next: LiveActivityContentState) => liveActivityAlert(old, next, selection, now);
    const assignmentAlert = { title: "Track 7", body: "Board at track 7 at New York Penn." };
    expect(alert(base, assigned)).toEqual(assignmentAlert);
    expect(alert(assigned, { ...assigned, platform: "9" })).toEqual({ title: "Track changed to 9",
      body: "Now boarding at track 9 at New York Penn, not 7." });
    expect(alert({ ...assigned, platform: "5", platformBasis: "predicted" }, assigned)).toEqual(assignmentAlert);
    expect(alert({ ...assigned, platformBasis: "predicted" }, assigned)).toEqual(assignmentAlert);
    expect(alert({ ...assigned, platform: "3", focusName: "Washington Union" }, assigned)).toEqual(assignmentAlert);
    expect(alert(assigned, { ...assigned, delayMinutes: 4 })).toBeNull();
    expect(alert(base, { ...assigned, platformBasis: "scheduled" })).toBeNull();
    expect(alert(base, { ...assigned, platformBasis: "predicted" })).toBeNull();
    expect(alert(base, { ...assigned, phase: "underway" })).toBeNull();
    expect(alert(base, { ...assigned, boardingPlatformSequence: 3 })).toBeNull();
    expect(alert(base, { ...assigned, validUntil: now })).toBeNull();
    expect(liveActivityAlert(base, assigned, { ...selection, isRiding: false }, now)).toBeNull();
    const { platformKind: _kind, ...platformAssigned } = assigned;
    expect(alert(base, platformAssigned)?.title).toBe("Platform 7");

    const payload = makeLiveActivityPayload({ activityId: "activity", token: "a".repeat(64), tokenGeneration: 1,
      environment: "sandbox", revision: 1, timestamp: 1_800_000_000, event: "update", content: assigned,
      expiresAt: 1_800_000_900_000, alert: alert(base, assigned)! });
    expect(payload.aps).toMatchObject({ alert: { title: "Track 7", body: "Board at track 7 at New York Penn.", sound: "default" } });
  });

  it("adds optional track kind and source for Amtraker trips without changing other content", () => {
    const fixture = fixtures.cases.find((value) => value.input.boardingStationID !== null)!;
    const base = snapshot(fixture);
    const amtrak: TripSnapshot = { ...base, source: "amtraker",
      stops: base.stops.map((stop) => ({ ...stop, expectedPlatform: "17", plannedPlatform: "17", platformSource: "Amtraker" })) };
    const projected = projectLiveActivity({ ...fixture.input, trip: amtrak,
      boardingStationId: fixture.input.boardingStationID, alightingStationId: fixture.input.alightingStationID });
    expect(projected.state.platformKind).toBe("track");
    if (projected.state.platform !== null) expect(projected.state.platformSource).toBe("Amtraker");
    const other = projectLiveActivity({ ...fixture.input, trip: base,
      boardingStationId: fixture.input.boardingStationID, alightingStationId: fixture.input.alightingStationID });
    expect(other.state).not.toHaveProperty("platformKind");
    expect(other.state).not.toHaveProperty("platformSource");
  });

  it("marks Amtrak trains carried by Transitous as tracks too", () => {
    const fixture = fixtures.cases.find((value) => value.input.boardingStationID !== null)!;
    const base = snapshot(fixture);
    const viaTransitous: TripSnapshot = {
      ...base,
      source: "transitous",
      id: "eu:transitous:20261025_06:20_us-Amtrak_296943",
      nativeId: "20261025_06:20_us-Amtrak_296943",
      operatorName: "",
    };
    const projected = projectLiveActivity({ ...fixture.input, trip: viaTransitous,
      boardingStationId: fixture.input.boardingStationID, alightingStationId: fixture.input.alightingStationID });
    expect(projected.state.platformKind).toBe("track");
    const byOperator = projectLiveActivity({ ...fixture.input, trip: { ...base, source: "transitous", operatorName: "Amtrak" },
      boardingStationId: fixture.input.boardingStationID, alightingStationId: fixture.input.alightingStationID });
    expect(byOperator.state.platformKind).toBe("track");
  });
  it("keeps delayed Amtrak underway after scheduled arrival only while actual GPS is fresh", () => {
    const fixture = fixtures.cases.find((value) => value.name === "fresh-http-check-does-not-confirm-arrival")!;
    const base = snapshot(fixture);
    const position = { latitude: 39.5, longitude: -76.5, heading: null, source: "real" as const,
      confidence: 1, asOf: new Date((fixture.input.referenceDate - 60) * 1_000).toISOString(), provider: "Amtraker" };
    const project = (trip: TripSnapshot) => projectLiveActivity({ ...fixture.input, trip });
    const active = project({ ...base, operatorName: "Amtrak", positions: [position] });
    expect(active.state.phase).toBe("underway");
    expect(active.eligibility).toBe("available");
    expect(active.shouldEnd).toBe(false);
    const stale = project({ ...base, positions: [{ ...position,
      asOf: new Date((fixture.input.referenceDate - 301) * 1_000).toISOString() }] });
    expect(stale.state.phase).toBe("unavailable");
    expect(stale.shouldEnd).toBe(false);
    expect(stale.state.validUntil).toBeLessThanOrEqual(fixture.input.referenceDate);
    expect(project({ ...base, positions: [{ ...position, source: "inferred" }] }).state.phase).toBe("unavailable");
  });

  it("requires explicit observed arrival or passage before ending, never inferred passed flags", () => {
    const fixture = fixtures.cases.find((value) => value.name === "fresh-http-check-does-not-confirm-arrival")!;
    const base = snapshot(fixture);
    const observed = new Date((fixture.input.referenceDate - 1_800) * 1_000).toISOString();
    const project = (evidence: Partial<StopSnapshot>) => projectLiveActivity({ ...fixture.input,
      trip: { ...base, stops: base.stops.map((stop, index) => index === base.stops.length - 1
        ? { ...stop, ...evidence } : stop) } });
    expect(project({ passed: true }).shouldEnd).toBe(false);
    expect(project({ passed: true }).state.phase).toBe("unavailable");
    expect(project({ arrivalObservedAt: observed }).shouldEnd).toBe(true);
    expect(project({ passed: true, passageObservedAt: observed }).shouldEnd).toBe(true);
    expect(project({ passed: false, passageObservedAt: observed }).shouldEnd).toBe(false);
    expect(project({ arrivalObservedAt: "invalid" }).shouldEnd).toBe(false);
    expect(project({ arrivalObservedAt: new Date((fixture.input.referenceDate + 121) * 1_000).toISOString() }).shouldEnd).toBe(false);
    const justArrived = project({ arrivalObservedAt: new Date(fixture.input.referenceDate * 1_000).toISOString(),
      expectedArrival: new Date(fixture.input.referenceDate * 1_000).toISOString() });
    expect(justArrived.state.phase).toBe("ended");
    expect(justArrived.shouldEnd).toBe(false);
    expect(project({ arrivalObservedAt: new Date(fixture.input.referenceDate * 1_000).toISOString() }).shouldEnd).toBe(true);
  });

  it("does not end on an older arrival report contradicted by a newer route position before the destination", () => {
    const fixture = fixtures.cases.find((value) => value.name === "fresh-http-check-does-not-confirm-arrival")!;
    const base = snapshot(fixture);
    const trip: TripSnapshot = { ...base, stops: base.stops.map((stop, index) => index === base.stops.length - 1
      ? { ...stop, latitude: 39, longitude: -77, arrivalObservedAt: new Date((fixture.input.referenceDate - 1_800) * 1_000).toISOString() }
      : { ...stop, latitude: 40 - index * 0.25, longitude: -77 }), positions: [{ latitude: 39.5, longitude: -77, heading: null, source: "real", confidence: 1,
        asOf: new Date((fixture.input.referenceDate - 60) * 1_000).toISOString(), provider: "Amtraker" }] };
    const projection = projectLiveActivity({ ...fixture.input, trip });
    expect(projection.state.phase).toBe("underway");
    expect(projection.shouldEnd).toBe(false);
  });

});
