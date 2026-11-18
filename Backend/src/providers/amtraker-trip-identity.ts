import type { CanonicalTripReference } from "../domain/snapshot.js";
import type { AmtrakerTrain } from "./amtraker.js";

function boardingDateMatches(value: string, serviceDate: string, exactInstance: boolean): boolean {
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return false;
  const days = [value.slice(0, 10), date.toISOString().slice(0, 10)];
  if (days.includes(serviceDate)) return true;
  if (!exactInstance) return false;
  // A saved expected boarding day can move back across midnight after a delay is corrected.
  // Exact IDs still need nearby date evidence because trainID's day-of-month is reused.
  const requestedDay = Date.parse(`${serviceDate}T00:00:00Z`);
  return days.some((day) => Math.abs(Date.parse(`${day}T00:00:00Z`) - requestedDay) === 86_400_000);
}

/** Legacy boards save the source-local expected boarding day; other callers use UTC dates. */
export function amtrakerTripForReference(
  candidates: AmtrakerTrain[], reference: CanonicalTripReference,
): AmtrakerTrain | null {
  const exact = candidates.filter((train) => train.trainID === reference.nativeId);
  const eligible = exact.length > 0 ? exact : candidates.filter((train) => train.trainNum === reference.nativeId);
  const matches = eligible.filter((train) => train.stations.some((stop) =>
    [stop.schArr, stop.schDep, stop.arr, stop.dep].some((value) =>
      typeof value === "string" && boardingDateMatches(value, reference.serviceDate, exact.length > 0)),
  ));
  // Overlapping long-distance trains cannot be identified from a train number alone.
  return matches.length === 1 ? matches[0]! : null;
}
