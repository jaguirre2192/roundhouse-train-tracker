import type { TripSnapshot } from "../domain/snapshot.js";
import type { CoverageConfiguration, CoverageFeature, CoverageSupport, TripCoveragePolicy } from "../domain/trip-coverage.js";
import { enturServiceJourneyId } from "../providers/entur-service-identity.js";
import { golemioTripIdentity } from "../providers/golemio-trip-match.js";
import { gtfsCountryForNativeID } from "../providers/mainline-gtfs-provider.js";
import { denmarkSiriTrainNumber, isDenmarkSiriEligibleSnapshot } from "../providers/denmark-siri-matching.js";
import { isOfficialTraService, isTaiwanTimetable } from "./taiwan-trip-coverage.js";

const features: CoverageFeature[] = ["delays", "cancellations", "platforms", "position"];
const operational: CoverageFeature[] = ["delays", "cancellations", "platforms"];

function validDate(value: string): boolean {
  const time = Date.parse(`${value}T00:00:00Z`);
  return /^\d{4}-\d{2}-\d{2}$/u.test(value) && Number.isFinite(time)
    && new Date(time).toISOString().slice(0, 10) === value;
}

function allIn(snapshot: TripSnapshot, countries: readonly string[]): boolean {
  return snapshot.stops.length > 0 && snapshot.stops.every((stop) => countries.includes(stop.countryCode.toUpperCase()));
}

/** A namespace establishes source scope, never a current realtime observation. */
function nativeScope(snapshot: TripSnapshot, namespace: RegExp, countries: readonly string[]): boolean {
  if (snapshot.source !== "transitous" || !validDate(snapshot.serviceDate) || !allIn(snapshot, countries)) return false;
  const native = /^(\d{8})_(\d{1,2}):(\d{2})_(.+)$/u.exec(snapshot.nativeId);
  return native !== null && native[1] === snapshot.serviceDate.replaceAll("-", "")
    && Number(native[2]) < 72 && Number(native[3]) < 60 && namespace.test(native[4]!);
}

interface ScopedIntegration {
  namespace: RegExp;
  countries: readonly string[];
  sourceId: string;
  scopeName: string;
  enabledId?: string;
  position?: boolean;
  accepts?: (snapshot: TripSnapshot) => boolean;
}

// Mature adapters identify these national-source services. Foreign feed IDs,
// cross-border joins and unresolved operators remain unknown in this pure policy.
const integrations: ScopedIntegration[] = [
  { namespace: /^be-sncb_.+$/u, countries: ["BE"], sourceId: "irail", scopeName: "SNCB / NMBS" },
  { namespace: /^fi-digitraffic_\d+_\d{8}$/u, countries: ["FI"], sourceId: "digitraffic", scopeName: "Fintraffic rail", position: true, accepts: (trip) => trip.nativeId.endsWith(trip.serviceDate.replaceAll("-", "")) },
  { namespace: /^fr-horaires-sncf_.+$/u, countries: ["FR", "MC"], sourceId: "sncf", scopeName: "SNCF" },
  { namespace: /^at-Railway-Current-Reference-Data-\d{4}_.+$/u, countries: ["AT"], sourceId: "oebb", scopeName: "ÖBB rail" },
  { namespace: /^de-DELFI_.+$/u, countries: ["DE"], sourceId: "db-timetables", scopeName: "German rail", enabledId: "db-timetables" },
  { namespace: /^ch-opentransportdataswiss\d{2}_\.ojp-[^\s_]+$/u, countries: ["CH", "LI"], sourceId: "swiss", scopeName: "Swiss rail", enabledId: "swiss" },
  { namespace: /^nl-OpenOV_.+$/u, countries: ["NL"], sourceId: "ns", scopeName: "Dutch rail", enabledId: "ns" },
  { namespace: /^gb-great-britain_[A-Z]\d{5}(?:_|$)/u, countries: ["GB"], sourceId: "darwin", scopeName: "Great Britain rail", enabledId: "darwin" },
];

/** Configuration describes enabled integrations, not access rights or publication. */
export function tripCoveragePolicy(snapshot: TripSnapshot, configuration: CoverageConfiguration): TripCoveragePolicy {
  const policy: TripCoveragePolicy = {
    scopeName: snapshot.operatorName.trim() || "This train",
    sourceIds: [snapshot.source],
    support: { delays: "unknown", cancellations: "unknown", platforms: "unknown", position: "unknown" },
    limitationCodes: ["coverageUnknown"],
  };
  const set = (selected: readonly CoverageFeature[], support: CoverageSupport): void => {
    for (const feature of selected) policy.support[feature] = support;
  };
  const scope = (name: string, sourceId: string, limits: string[] = ["exactServiceMatch"]): void => {
    policy.scopeName = name;
    policy.sourceIds = [...new Set([snapshot.source, sourceId])];
    policy.limitationCodes = limits;
  };

  if (snapshot.source === "chepe" || snapshot.source === "srbijavoz") {
    set(features, "notProvided");
    scope(snapshot.source === "chepe" ? "Chepe Express" : "Srbija Voz published timetable", snapshot.source, ["timetableOnly"]);
    return policy;
  }
  if (!validDate(snapshot.serviceDate)) return policy;
  if (isTaiwanTimetable(snapshot) && allIn(snapshot, ["TW"])) {
    set(features, "notProvided");
    scope(snapshot.operatorName, snapshot.source === "tdx" ? "tdx" : "tdx-mirror", ["timetableOnly"]);
    if (isOfficialTraService(snapshot) && (snapshot.source === "tdx" || configuration.enabledSources.has("tdx"))) {
      if (!policy.sourceIds.includes("tdx")) policy.sourceIds.push("tdx");
      set(operational, "unknown");
      policy.limitationCodes = ["operatorScope", "exactServiceMatch", "partialCallUpdates"];
    }
    return policy;
  }
  if (snapshot.source === "transitous" && gtfsCountryForNativeID(snapshot.nativeId) === "KR" && allIn(snapshot,["KR"])) {
    set(features,"notProvided");
    scope("Korail","korail-mkuran",["timetableOnly","wholeTripDelayOnly"]);
    return policy;
  }
  if (snapshot.source === "amtraker") {
    set(features, "connected");
    scope("Amtrak", "amtraker", ["sparsePlatforms", "positionVaries"]);
    return policy;
  }
  // Imported Amtrak operator text cannot prove the Amtraker station/time join.
  if (snapshot.source !== "transitous") return policy;

  if (golemioTripIdentity(snapshot) !== null) {
    scope("PID regional rail", "golemio-pid", ["regionalScope", "exactServiceMatch"]);
    if (configuration.enabledSources.has("golemio-pid")) set(["position"], "connected");
    else policy.limitationCodes.push("runtimeSourceDisabled");
    return policy;
  }
  if (nativeScope(snapshot, /^lv-pieturas_pv-\d+$/u, ["LV"])) {
    // Full-looking static calls cannot substitute for the complete Vivi TU join.
    scope("Vivi regional rail", "vivi", ["regionalScope", "exactServiceMatch", "coverageUnknown"]);
    return policy;
  }
  if (nativeScope(snapshot, /^se-Trafiklab_.+$/u, ["SE"])) {
    // Neither an agency string nor a bundled index proves the current maintained
    // national-to-regional match. The assessor may promote genuine observations.
    scope("Swedish rail", "transitous", ["operatorScope", "exactServiceMatch", "coverageUnknown"]);
    return policy;
  }
  const entur = enturServiceJourneyId(snapshot);
  if (entur !== null && allIn(snapshot, ["NO"]) && !/:ServiceJourney:BUS[-_]/iu.test(entur)) {
    scope(entur.startsWith("VYG:") ? "Vy rail" : "Norwegian rail", "entur", ["operatorScope", "exactServiceMatch", "positionVaries"]);
    if (entur.startsWith("VYG:")) set(features, "connected");
    return policy;
  }
  if (nativeScope(snapshot, /^au-nsw-Transport-for-New-South-Wales-nsw-trains_[^\s]+$/u, ["AU"])
    && !/\b(?:coach|bus)\b/iu.test(snapshot.product)) {
    scope("NSW TrainLink rail", "tfnsw", ["regionalScope", "exactServiceMatch", "positionVaries"]);
    if (configuration.enabledSources.has("tfnsw")) set(features, "connected");
    else policy.limitationCodes.push("runtimeSourceDisabled");
    return policy;
  }
  if (nativeScope(snapshot, /^ca-viarail_[^\s]+$/iu, ["CA"])) {
    // This exact namespace is served by the public, date-matched VIA GPS lane.
    set(["position"], "connected");
    scope("VIA Rail", "via", ["exactServiceMatch", "positionVaries"]);
    return policy;
  }
  if (nativeScope(snapshot, /^(?:dk-rejseplanen|de-DELFI|se-Trafiklab)_.+$/u, ["DK"])
    && isDenmarkSiriEligibleSnapshot(snapshot) && denmarkSiriTrainNumber(snapshot) !== null) {
    // Authorized access establishes the narrow source scope. Only fresh matched
    // call evidence can promote current delay availability in the assessor.
    set(["position"], "notProvided");
    scope(`${snapshot.operatorName} Danish rail`, "denmark-siri", ["operatorScope", "exactServiceMatch", "partialCallUpdates", "coverageUnknown"]);
    return policy;
  }
  if (nativeScope(snapshot, /^dk-rejseplanen_.+$/u, ["DK"])) {
    set(["position"], "notProvided");
    scope("Danish rail", "transitous", ["providerAccessPending", "coverageUnknown"]);
    return policy;
  }
  if (nativeScope(snapshot, /^pt-Comboios-de-Portugal\(CP\)_.+$/u, ["PT"])) {
    if (!configuration.enabledSources.has("cp")) set(["position"], "notProvided");
    scope("Comboios de Portugal", "transitous", ["providerAccessPending", "coverageUnknown"]);
    return policy;
  }
  for (const integration of integrations) {
    if (!nativeScope(snapshot, integration.namespace, integration.countries)
      || (integration.accepts !== undefined && !integration.accepts(snapshot))) continue;
    scope(integration.scopeName, integration.sourceId);
    set(["position"], integration.position === true ? "unknown" : "notProvided");
    if (integration.enabledId === undefined || configuration.enabledSources.has(integration.enabledId)) {
      set(operational, "connected");
      if (integration.position === true) set(["position"], "connected");
    } else policy.limitationCodes.push("runtimeSourceDisabled");
    return policy;
  }
  return policy;
}
