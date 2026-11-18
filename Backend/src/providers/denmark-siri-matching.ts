import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import type { PlatformObservation } from "./platform-overlay.js";
import { denmarkSiriMaximumAgeMilliseconds, denmarkSiriSourceName, type DenmarkSiriCall, type DenmarkSiriJourney, type DenmarkSiriOperatorRef } from "./denmark-siri-models.js";

/** Exact seven-digit Danish code only; never truncate a foreign nine-digit namespace. */
export function denmarkSiriStationCode(stationId: string): string | null {
  const match = /^(?:eu:transitous:)?(?:dk-rejseplanen|de-DELFI|se-Trafiklab)_(0*86\d{5})$/u.exec(stationId);
  return match === null ? null : match[1]!.replace(/^0+/u, "");
}

export function denmarkSiriTrainNumber(snapshot: Pick<TripSnapshot, "product">): string | null {
  const numbers = snapshot.product.match(/\d+/gu) ?? [];
  return numbers.length === 1 && /^\d{1,6}$/u.test(numbers[0]!) ? numbers[0]!.replace(/^0+/u, "") || "0" : null;
}

function scheduledTimesAgree(stop: StopSnapshot, call: DenmarkSiriCall): boolean {
  let anchors = 0;
  for (const [scheduled, aimed] of [[stop.scheduledArrival, call.aimedArrival], [stop.scheduledDeparture, call.aimedDeparture]]) {
    if (scheduled === null || scheduled === undefined || aimed === null || aimed === undefined) continue;
    if (!Number.isFinite(Date.parse(scheduled)) || Date.parse(scheduled) !== Date.parse(aimed)) return false;
    anchors++;
  }
  return anchors > 0;
}

function snapshotOperator(snapshot: TripSnapshot): DenmarkSiriOperatorRef | null {
  if (snapshot.source !== "transitous"
    || !/(?:^|_)(?:dk-rejseplanen|de-DELFI|se-Trafiklab)_/u.test(snapshot.nativeId)) return null;
  // This separately observed regional operator must never match the DSB branch.
  if (snapshot.operatorName === "DSB Vores Tog") return "DSB Vores Tog";
  const operator = snapshot.operatorName.normalize("NFKD").replace(/\p{Diacritic}/gu, "").toLowerCase();
  return ["dsb", "danske statsbaner", "danische staatsbahnen"].includes(operator) ? "DSB" : null;
}

export function isDenmarkSiriEligibleSnapshot(snapshot: TripSnapshot): boolean {
  return snapshotOperator(snapshot) !== null;
}

/** Dated public train number plus two exact station/time anchors; ambiguous runs are withheld. */
export function denmarkSiriObservations(
  snapshot: TripSnapshot, journeys: readonly DenmarkSiriJourney[], now: Date,
): PlatformObservation[] {
  const instant = now.getTime();
  const number = denmarkSiriTrainNumber(snapshot);
  const operator = snapshotOperator(snapshot);
  if (operator === null || number === null || !Number.isFinite(instant)) return [];
  const candidates: PlatformObservation[][] = [];
  for (const journey of journeys) {
    if (journey.operatorRef !== operator || journey.trainNumber !== number || journey.serviceDate !== snapshot.serviceDate) continue;
    const observations: PlatformObservation[] = [];
    const stations = new Set<string>();
    let contradiction = false;
    for (const call of journey.calls) {
      const observed = Date.parse(call.observedAt);
      if (call.conflicted === true || !Number.isFinite(observed) || observed > instant + 120_000
        || instant - observed > denmarkSiriMaximumAgeMilliseconds) continue;
      const sameStation = snapshot.stops.filter((stop) => stop.countryCode === "DK"
        && denmarkSiriStationCode(stop.stationId) === call.stopPointRef);
      const matches = sameStation.filter((stop) => scheduledTimesAgree(stop, call));
      if (matches.length !== 1) {
        if (sameStation.length > 0) contradiction = true;
        continue;
      }
      const stop = matches[0]!;
      stations.add(call.stopPointRef);
      const expectedArrival = stop.scheduledArrival === null || call.aimedArrival === null ? undefined : call.expectedArrival;
      const expectedDeparture = stop.scheduledDeparture === null || call.aimedDeparture === null ? undefined : call.expectedDeparture;
      if (expectedArrival === undefined && expectedDeparture === undefined) continue;
      observations.push({ stopSequence: stop.sequence, stationId: stop.stationId, observedAt: call.observedAt,
        source: denmarkSiriSourceName,
        ...(expectedArrival === undefined ? {} : { expectedArrival }),
        ...(expectedDeparture === undefined ? {} : { expectedDeparture }) });
    }
    if (!contradiction && stations.size >= 2) candidates.push(observations);
  }
  return candidates.length === 1 ? candidates[0]! : [];
}
