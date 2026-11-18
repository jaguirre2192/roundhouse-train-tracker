import { describe, expect, it } from "vitest";
import { arrivalReport, boardView, fallbackExpiry, makeBoardRecord, selectedCall, unreportedArrivalGrace } from "../src/domain/arrival-board.js";
import type { CanonicalTripReference, StopSnapshot, TripSnapshot } from "../src/domain/snapshot.js";

const now = Date.parse("2026-11-18T08:00:00Z");
const ref: CanonicalTripReference = { id: "eu:transitous:test", source:"transitous", nativeId:"test", serviceDate:"2026-11-18" };
const call: StopSnapshot = { stationId: "mid", stationName:"Zaragoza-Delicias", sequence:2, countryCode:"ES", latitude:41, longitude:-1,
  scheduledArrival:"2026-11-18T07:55:00Z", scheduledDeparture:null, expectedArrival:"2026-11-18T08:20:00Z", expectedDeparture:null,
  expectedArrivalEvidence:{ source:"Renfe", observedAt:"2026-11-18T07:57:00Z" }, plannedPlatform:null, expectedPlatform:null,
  platformSource:null, platformObservedAt:null, cancelled:false, passed:true };
const trip: TripSnapshot = { ...ref, operatorName:"Renfe", product:"AVE 03123", headsign:"Barcelona", fetchedAt:new Date(now).toISOString(), stops:[call], alertIds:[] };
const record = makeBoardRecord({ trip:ref, stationId:"mid", sequence:2, note:null, timeZone:"Europe/Madrid" }, trip, call);
const view = (s: StopSnapshot | null) => boardView(record, s, trip.fetchedAt, s ? arrivalReport(s, now) : null, now + 3600_000, now);

describe("recipient arrival board evidence", () => {
  it("keeps a delayed Spanish timetable stop ahead despite an unqualified passed flag", () => {
    expect(view(call)).toMatchObject({ basis:"estimated", delayMinutes:25, time:"2026-11-18T08:20:00.000Z", reportedAt:"2026-11-18T07:57:00.000Z" });
  });
  it("never renews a stale or future per-stop report by fetching the snapshot again", () => {
    for (const stamp of ["2026-11-18T07:00:00Z", "2026-11-18T10:00:00Z", "invalid"]) {
      expect(view({ ...call, expectedArrivalEvidence:{ source:"Renfe", observedAt:stamp } })).toMatchObject({ basis:"scheduled", delayMinutes:null, reportedAt:null });
    }
  });
  it("keeps checked time, timetable echoes, cancellations and actual passage semantically separate", () => {
    const {expectedArrivalEvidence: _evidence, ...undated} = call;
    expect(boardView(record, undated, "2026-11-17T07:00:00Z", null, now + 3_600_000, now)).toMatchObject({ basis:"scheduled", delayMinutes:null });
    expect(view({ ...undated, expectedArrival:call.scheduledArrival })).toMatchObject({ basis:"scheduled", delayMinutes:null, reportedAt:null });
    expect(view({ ...call, cancelled:true })).toMatchObject({ basis:"cancelled", time:null, delayMinutes:null });
    expect(view({ ...call, passed:true, passageObservedAt:"2026-11-18T07:58:00Z" })).toMatchObject({ basis:"passed", delayMinutes:null });
    expect(view({ ...call, arrivalObservedAt:"2026-11-18T07:57:00Z" })).toMatchObject({ basis:"arrived", delayMinutes:2 });
    expect(view(null)).toMatchObject({ basis:"scheduled", updatesAvailable:false, delayMinutes:null });
  });
  it("anchors the fallback cutoff to the later train arrival, never to the time the link is read", () => {
    expect(fallbackExpiry(call, now, trip.fetchedAt)).toBe(Date.parse(call.expectedArrival!) + unreportedArrivalGrace);
    expect(fallbackExpiry({ ...call, scheduledArrival:null, expectedArrival:null }, now, trip.fetchedAt)).toBeNull();
  });
  it("requires the selected occurrence at a repeated station and prefers its operator time zone", () => {
    const second = { ...call, sequence:5, timeZoneIdentifier:"Europe/Madrid" };
    expect(selectedCall({ ...trip, stops:[call, second] }, { stationId:"mid", sequence:5 })).toEqual(second);
    expect(selectedCall(trip, { stationId:"mid", sequence:5 })).toBeNull();
    expect(makeBoardRecord({ ...record, timeZone:"America/New_York" }, trip, second).timeZone).toBe("Europe/Madrid");
  });
});
