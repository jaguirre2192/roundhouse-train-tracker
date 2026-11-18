import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import type { AmtrakerStop, AmtrakerTrain } from "./amtraker.js";

function stationsCorrespond(saved: StopSnapshot, stop: AmtrakerStop): boolean {
  const code = saved.stationId.split(/[_:]/u).at(-1) ?? "";
  if (/^[A-Z]{3}$/u.test(code)) return code === stop.code.toUpperCase();
  const normalize = (name: string) => name.toLowerCase().split(/[^a-z0-9]+/u)
    .filter((word) => word.length > 0 && word !== "station").join(" ");
  const left = normalize(saved.stationName), right = normalize(stop.name);
  return left.length > 0 && right.length > 0
    && (left === right || left.startsWith(`${right} `) || right.startsWith(`${left} `));
}

function sameEvent(left: string | null, right: string | null | undefined): boolean {
  if (left === null || right == null) return false;
  const a = Date.parse(left), b = Date.parse(right);
  return Number.isFinite(a) && Number.isFinite(b) && Math.abs(a - b) <= 90_000;
}

/** Match both directions uniquely; repeated/ambiguous calls never borrow one another's evidence. */
export function matchedAmtrakerStops(snapshot: TripSnapshot, train: AmtrakerTrain) {
  const matches = snapshot.stops.flatMap((saved) => {
    const candidates = train.stations.filter((reported) => stationsCorrespond(saved, reported)
      && (sameEvent(saved.scheduledDeparture, reported.schDep) || sameEvent(saved.scheduledArrival, reported.schArr)));
    return candidates.length === 1 ? [{ saved, reported: candidates[0]! }] : [];
  });
  return matches.filter(({ reported }) => matches.filter((other) => other.reported === reported).length === 1);
}

export function matchingAmtrakerTrain(snapshot: TripSnapshot, candidates: AmtrakerTrain[]): AmtrakerTrain | null {
  const matches = candidates.filter((candidate) => matchedAmtrakerStops(snapshot, candidate).length > 0);
  return matches.length === 1 ? matches[0]! : null;
}
