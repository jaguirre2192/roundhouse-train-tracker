import type { StopSnapshot } from "../domain/snapshot.js";
import type { AmtrakerStop, AmtrakerTrain } from "./amtraker.js";

/** Fetching a reported event again adds no evidence: only source timestamps qualify. */
export function amtrakerStopObservation(
  event: string | null | undefined, train: AmtrakerTrain, now: Date,
): string | undefined {
  for (const candidate of [event, train.lastValTS, train.updatedAt]) {
    const time = candidate == null ? Number.NaN : Date.parse(candidate);
    if (Number.isFinite(time) && time <= now.getTime() + 120_000) return new Date(time).toISOString();
  }
  return undefined;
}

export function amtrakerStopEvidence(
  stop: AmtrakerStop, train: AmtrakerTrain, now: Date,
): Partial<Pick<StopSnapshot, "passed" | "passageObservedAt" | "arrivalObservedAt">> {
  const status = stop.status?.toLowerCase();
  if (status === "departed") {
    const passageObservedAt = amtrakerStopObservation(stop.dep, train, now);
    return passageObservedAt === undefined ? {} : { passed: true, passageObservedAt };
  }
  if (status === "station") {
    // v3 also emits Station for future terminal rows with arr=null. Require an actual
    // nonfuture arrival value; a train-level update timestamp cannot prove this stop.
    const arrived = stop.arr == null ? Number.NaN : Date.parse(stop.arr);
    return Number.isFinite(arrived) && arrived <= now.getTime()
      ? { passed: false, arrivalObservedAt: new Date(arrived).toISOString() } : {};
  }
  if (status === "arrived") {
    const arrivalObservedAt = amtrakerStopObservation(stop.arr, train, now);
    return arrivalObservedAt === undefined ? {} : { passed: false, arrivalObservedAt };
  }
  return {};
}
