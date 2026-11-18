import type { StopSnapshot } from "./snapshot.js";

function validObservation(value: string | undefined, referenceDate: string): boolean {
  if (value === undefined) return false;
  const observed = Date.parse(value);
  const reference = Date.parse(referenceDate);
  return Number.isFinite(observed) && Number.isFinite(reference) && observed <= reference + 120_000;
}

export function hasReportedPassage(stop: StopSnapshot, referenceDate: string): boolean {
  return stop.passed && validObservation(stop.passageObservedAt, referenceDate);
}

export function hasReportedArrival(stop: StopSnapshot, referenceDate: string): boolean {
  return validObservation(stop.arrivalObservedAt, referenceDate) || hasReportedPassage(stop, referenceDate);
}
