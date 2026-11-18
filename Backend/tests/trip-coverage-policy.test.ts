import { describe, expect, it } from "vitest";
import type { ProviderSource, TripSnapshot } from "../src/domain/snapshot.js";
import { tripCoveragePolicy } from "../src/services/trip-coverage-policy.js";

const unknown = { delays: "unknown", cancellations: "unknown", platforms: "unknown", position: "unknown" };
const connected = { delays: "connected", cancellations: "connected", platforms: "connected", position: "connected" };
const timetable = { delays: "notProvided", cancellations: "notProvided", platforms: "notProvided", position: "notProvided" };
function trip(nativeId = "20261113_18:00_cz-PID_1004_6928_260601", countries = ["CZ", "CZ"]): TripSnapshot {
  return {
    id: `eu:transitous:${nativeId}`, source: "transitous", nativeId, serviceDate: "2026-11-13",
    operatorName: "Example Rail", product: "R 123", headsign: "Destination", fetchedAt: "2026-11-13T18:00:00Z", alertIds: [],
    stops: countries.map((countryCode, index) => ({
      stationId: `eu:transitous:stop-${index}`, stationName: `Station ${index}`, countryCode,
      latitude: 50, longitude: 14 + index, sequence: index + 1,
      scheduledArrival: index === 0 ? null : "2026-11-13T18:00:00Z",
      scheduledDeparture: index === 0 ? "2026-11-13T17:00:00Z" : null,
      expectedArrival: null, expectedDeparture: null, plannedPlatform: null, expectedPlatform: null,
      platformSource: null, platformObservedAt: null, cancelled: false, passed: false,
    })),
  };
}
const policy = (snapshot: TripSnapshot, enabled: string[] = []) =>
  tripCoveragePolicy(snapshot, { enabledSources: new Set(enabled) });

describe("trip coverage service-scope policy", () => {
  it.each(["chepe", "srbijavoz"] as ProviderSource[])("declares explicit %s schedule-only service", (source) => {
    const snapshot = trip(); snapshot.source = source;
    expect(policy(snapshot).support).toEqual(timetable);
    expect(policy(snapshot).limitationCodes).toEqual(["timetableOnly"]);
  });
  it("retains sparse-platform and position limits for direct Amtraker", () => {
    const snapshot = trip(); snapshot.source = "amtraker";
    expect(policy(snapshot)).toMatchObject({ scopeName: "Amtrak", sourceIds: ["amtraker"], support: connected,
      limitationCodes: ["sparsePlatforms", "positionVaries"] });
  });
  it("never uses observed fields or operator text to establish imported Amtrak policy", () => {
    const snapshot = trip("20261113_18:00_us-Amtrak_123", ["US", "US"]);
    snapshot.operatorName = "Amtrak"; snapshot.stops[0]!.expectedDeparture = "2026-11-13T17:10:00Z";
    snapshot.stops[0]!.expectedPlatform = "4"; snapshot.stops[0]!.cancelled = true;
    snapshot.positions = [{ latitude: 40, longitude: -74, source: "real", confidence: 1, heading: null,
      asOf: snapshot.fetchedAt, provider: "Amtraker" }];
    expect(policy(snapshot).support).toEqual(unknown);
  });
  it("connects only PID position after the runtime gate and complete origin identity", () => {
    expect(policy(trip(), ["golemio-pid"]).support).toEqual({ ...unknown, position: "connected" });
    expect(policy(trip()).support).toEqual(unknown);
    expect(policy(trip()).limitationCodes).toContain("runtimeSourceDisabled");
  });
  it.each(["date", "invalid-date", "origin", "partial", "namespace", "source", "country"])(
    "does not claim PID GPS for a %s mismatch", (kind) => {
      const snapshot = trip();
      if (kind === "date") snapshot.serviceDate = "2026-11-14";
      if (kind === "invalid-date") snapshot.serviceDate = "2026-11-31";
      if (kind === "origin") snapshot.stops[0]!.scheduledDeparture = "2026-11-13T17:02:00Z";
      if (kind === "partial") snapshot.stops.shift();
      if (kind === "namespace") snapshot.nativeId = snapshot.nativeId.replace("cz-PID", "cz-other");
      if (kind === "source") snapshot.source = "sncf";
      if (kind === "country") snapshot.stops.forEach((stop) => { stop.countryCode = "DE"; });
      expect(policy(snapshot, ["golemio-pid"]).support.position).toBe("unknown");
    },
  );
  it("retains unknown Vivi/Skåne/SJ capability without the full live/static join", () => {
    for (const [native, country, operator] of [
      ["lv-pieturas_pv-6168", "LV", "Vivi"], ["se-Trafiklab_40001231", "SE", "Skånetrafiken"],
      ["se-Trafiklab_40001232", "SE", "SJ"], ["se-Trafiklab_40001233", "SE", "Snälltåget"],
    ]) {
      const snapshot = trip(`20261113_18:00_${native}`, [country!, country!]); snapshot.operatorName = operator!;
      expect(policy(snapshot, ["trafiklab-regional", "trafiklab-national", "trafiklab-timetables"]).support).toEqual(unknown);
    }
  });
  it("restricts Norwegian capability to exact dated non-bus VYG scope", () => {
    const snapshot = trip("20261113_18:00_no-Entur_VYG:ServiceJourney:1828_481200-R", ["NO", "NO"]);
    expect(policy(snapshot).support).toEqual(connected);
    for (const nativeId of ["20261112_18:00_no-Entur_VYG:ServiceJourney:1828_481200-R",
      "20261113_18:00_no-Entur_SJN:ServiceJourney:1828_481200-R",
      "20261113_18:00_no-Entur_VYG:ServiceJourney:BUS-825_761674-R", "no-Entur_R40"]) {
      expect(policy({ ...snapshot, nativeId }).support).toEqual(unknown);
    }
    expect(policy({ ...snapshot, stops: [snapshot.stops[0]!, { ...snapshot.stops[1]!, countryCode: "SE" }] }).support).toEqual(unknown);
  });
  it("requires enabled exact NSW rail scope rather than an Australian operator match", () => {
    const snapshot = trip("20261113_20:42_au-nsw-Transport-for-New-South-Wales-nsw-trains_N711", ["AU", "AU"]);
    expect(policy(snapshot, ["tfnsw"]).support).toEqual(connected);
    expect(policy(snapshot).support).toEqual(unknown);
    expect(policy({ ...snapshot, product: "Coach 711" }, ["tfnsw"]).support).toEqual(unknown);
    expect(policy({ ...snapshot, nativeId: snapshot.nativeId.replace("nsw-trains", "sydneytrains") }, ["tfnsw"]).support).toEqual(unknown);
    expect(policy({ ...snapshot, serviceDate: "2026-11-14" }, ["tfnsw"]).support).toEqual(unknown);
  });
  it("connects only VIA position for a dated local VIA namespace", () => {
    const snapshot = trip("20261113_18:00_ca-Viarail_557", ["CA", "CA"]);
    expect(policy(snapshot).support).toEqual({ ...unknown, position: "connected" });
    expect(policy({ ...snapshot, nativeId: snapshot.nativeId.replace("ca-Viarail", "ca-other") }).support).toEqual(unknown);
    expect(policy({ ...snapshot, serviceDate: "2026-11-14" }).support).toEqual(unknown);
    snapshot.stops[1]!.countryCode = "US";
    expect(policy(snapshot).support).toEqual(unknown);
  });
  it.each([["dk-rejseplanen_123", "DK"], ["pt-Comboios-de-Portugal(CP)_4428_20251214", "PT"]])(
    "keeps upstream operational fields unknown for %s", (native, country) => {
      const snapshot = trip(`20261113_18:00_${native}`, [country!, country!]);
      expect(policy(snapshot).support).toEqual({ ...unknown, position: "notProvided" });
      expect(policy({ ...snapshot, stops: [] }).support).toEqual(unknown);
      snapshot.stops[1]!.countryCode = "FR";
      expect(policy(snapshot).support).toEqual(unknown);
    },
  );
  it("leaves enabled CP position unknown until an operational join", () => {
    const snapshot = trip("20261113_18:00_pt-Comboios-de-Portugal(CP)_4428_20251214", ["PT", "PT"]);
    expect(policy(snapshot, ["cp"]).support).toEqual(unknown);
  });
  it.each([
    ["de-DELFI_123", "DE", "db-timetables"], ["ch-opentransportdataswiss26_.ojp-91-5-A.1.TA.986.j26", "CH", "swiss"],
    ["nl-OpenOV_123", "NL", "ns"], ["gb-great-britain_W34837_20260522_20261211", "GB", "darwin"],
  ])("requires runtime key, namespace/date and local-country scope for %s", (native, country, flag) => {
    const snapshot = trip(`20261113_18:00_${native}`, [country!, country!]);
    expect(policy(snapshot, [flag!]).support).toEqual({ ...connected, position: "notProvided" });
    expect(policy(snapshot).support).toEqual({ ...unknown, position: "notProvided" });
    expect(policy({ ...snapshot, serviceDate: "2026-11-14" }, [flag!]).support).toEqual(unknown);
    snapshot.stops[1]!.countryCode = "FR";
    expect(policy(snapshot, [flag!]).support).toEqual(unknown);
  });
  it("keeps foreign Swiss IDs and unrecognised British train IDs unknown", () => {
    expect(policy(trip("20261113_18:00_it-trenitalia_.ojp-91-X", ["CH", "CH"]), ["swiss"]).support).toEqual(unknown);
    expect(policy(trip("20261113_18:00_gb-great-britain_route-123", ["GB", "GB"]), ["darwin"]).support).toEqual(unknown);
  });
  it("validates Finland's operating date rather than inferring coverage from country", () => {
    expect(policy(trip("20261113_18:00_fi-digitraffic_183_20261113", ["FI", "FI"])).support).toEqual(connected);
    expect(policy(trip("20261113_18:00_fi-digitraffic_183_20261114", ["FI", "FI"])).support).toEqual(unknown);
    expect(policy(trip("20261113_18:00_unknown_183", ["FI", "FI"])).support).toEqual(unknown);
  });
  it.each([
    ["cz-PID_1004_6928_260601", "CZ", "golemio-pid"],
    ["no-Entur_VYG:ServiceJourney:1828_481200-R", "NO", ""],
    ["au-nsw-Transport-for-New-South-Wales-nsw-trains_N711", "AU", "tfnsw"],
    ["de-DELFI_123", "DE", "db-timetables"],
    ["fi-digitraffic_183_20261113", "FI", ""],
  ])("rejects a changed embedded native service day for %s", (native, country, flag) => {
    const snapshot = trip(`20261113_18:00_${native}`, [country!, country!]);
    snapshot.nativeId = snapshot.nativeId.replace("20261113_", "20261112_");
    expect(policy(snapshot, flag ? [flag] : []).support).toEqual(unknown);
  });
  it("never serializes enabled values and leaves inputs unchanged", () => {
    const snapshot = trip(); const before = structuredClone(snapshot);
    const config = { enabledSources: new Set(["golemio-pid", "test-private-secret"]) };
    expect(JSON.stringify(tripCoveragePolicy(snapshot, config))).not.toContain("test-private-secret");
    expect(snapshot).toEqual(before);
    expect([...config.enabledSources]).toEqual(["golemio-pid", "test-private-secret"]);
  });
});
