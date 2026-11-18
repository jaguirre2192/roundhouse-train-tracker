import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import type { PlatformObservation } from "./platform-overlay.js";
import type {
  IrishRailBoardRow,
  IrishRailMovement,
  IrishRailRun,
  IrishRailStation,
} from "./irish-rail-types.js";
import { apiDate } from "./irish-rail-xml.js";
import { zonedParts, zonedWallClockToUTC } from "./zoned-time.js";

function normalized(value: string): string {
  return value
    .normalize("NFKD")
    .replace(/\p{Diacritic}/gu, "")
    .replace(/\b(?:railway|station|stn)\b/giu, " ")
    .replace(/[^\p{Letter}\p{Number}]+/gu, " ")
    .trim()
    .toLowerCase();
}

function nameMatches(left: string, right: string): boolean {
  const first = normalized(left);
  const second = normalized(right);
  if (first.length === 0 || second.length === 0) return false;
  if (first === second) return true;
  const shorter = first.length < second.length ? first : second;
  const longer = first.length < second.length ? second : first;
  return shorter.length >= 4 && longer.split(" ").join(" ").includes(shorter);
}

function distanceKilometres(
  firstLatitude: number,
  firstLongitude: number,
  secondLatitude: number,
  secondLongitude: number,
): number {
  const radians = Math.PI / 180;
  const latitudeDelta = (secondLatitude - firstLatitude) * radians;
  const longitudeDelta = (secondLongitude - firstLongitude) * radians;
  const a = Math.sin(latitudeDelta / 2) ** 2
    + Math.cos(firstLatitude * radians) * Math.cos(secondLatitude * radians)
    * Math.sin(longitudeDelta / 2) ** 2;
  return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

export function irishRailStationForStop(
  stop: StopSnapshot,
  stations: IrishRailStation[],
): IrishRailStation | null {
  const named = stations.filter((station) => nameMatches(station.name, stop.stationName));
  if (named.length === 1) return named[0]!;
  if (stop.latitude === null || stop.longitude === null) return null;
  const nearby = stations.map((station) => ({
    station,
    distance: station.latitude === null || station.longitude === null
      ? Number.POSITIVE_INFINITY
      : distanceKilometres(stop.latitude!, stop.longitude!, station.latitude, station.longitude),
  })).filter((candidate) => candidate.distance <= 2)
    .sort((left, right) => left.distance - right.distance);
  if (nearby.length === 0) return null;
  if (nearby.length > 1 && nearby[1]!.distance - nearby[0]!.distance < 0.05) return null;
  return nearby[0]!.station;
}

function localDublinISO(year: number, month: number, day: number, hour: number, minute: number, second: number): string {
  return new Date(zonedWallClockToUTC("Europe/Dublin", year, month, day, hour, minute, second)).toISOString();
}

function clockNear(clock: string, anchor: string | null): string | null {
  if (anchor === null || /^00:00(?::00)?$/u.test(clock)) return null;
  const match = clock.match(/^(\d{1,2}):(\d{2})(?::(\d{2}))?$/u);
  const anchorDate = new Date(anchor);
  if (match === null || Number.isNaN(anchorDate.getTime())) return null;
  const parts = zonedParts(anchorDate.getTime(), "Europe/Dublin");
  const baseDate = new Date(Date.UTC(parts.year, parts.month - 1, parts.day));
  const candidates = [-1, 0, 1].map((offset) => {
    const date = new Date(baseDate.getTime() + offset * 86_400_000);
    return localDublinISO(
      date.getUTCFullYear(),
      date.getUTCMonth() + 1,
      date.getUTCDate(),
      Number(match[1]),
      Number(match[2]),
      Number(match[3] ?? 0),
    );
  });
  return candidates.sort((left, right) =>
    Math.abs(Date.parse(left) - anchorDate.getTime()) - Math.abs(Date.parse(right) - anchorDate.getTime())
  )[0] ?? null;
}

function apiDateTime(value: string): string | null {
  const match = value.trim().match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})\s+(\d{1,2}):(\d{2}):(\d{2})$/u);
  return match === null ? null : localDublinISO(
    Number(match[3]),
    Number(match[2]),
    Number(match[1]),
    Number(match[4]),
    Number(match[5]),
    Number(match[6]),
  );
}

export function matchingIrishRailRun(
  snapshot: TripSnapshot,
  stations: IrishRailStation[],
  runs: IrishRailRun[],
): IrishRailRun | null {
  const firstStop = snapshot.stops[0];
  const lastStop = snapshot.stops.at(-1);
  if (firstStop === undefined || lastStop === undefined || firstStop.scheduledDeparture === null) return null;
  const origin = irishRailStationForStop(firstStop, stations);
  const destination = irishRailStationForStop(lastStop, stations);
  if (origin === null || destination === null) return null;
  const candidates = runs.filter((run) => {
    const originTime = apiDateTime(run.originTime);
    return run.originCode === origin.code
      && run.destinationCode === destination.code
      && apiDate(run.trainDate) === snapshot.serviceDate
      && originTime !== null
      && Math.abs(Date.parse(originTime) - Date.parse(firstStop.scheduledDeparture!)) <= 6 * 60_000;
  });
  return candidates.length === 1 ? candidates[0]! : null;
}

function scheduled(stop: StopSnapshot): string | null {
  return stop.scheduledDeparture ?? stop.scheduledArrival;
}

function boardTime(row: IrishRailBoardRow, stop: StopSnapshot): string | null {
  const clock = stop.scheduledDeparture === null ? row.scheduledArrival : row.scheduledDeparture;
  return clockNear(clock, scheduled(stop));
}

export function matchingIrishRailBoardRow(
  snapshot: TripSnapshot,
  candidates: Array<{ row: IrishRailBoardRow; stop: StopSnapshot }>,
): IrishRailBoardRow | null {
  const origin = snapshot.stops[0]?.stationName ?? "";
  const destination = snapshot.stops.at(-1)?.stationName ?? "";
  const scored = candidates.flatMap(({ row, stop }) => {
    if (apiDate(row.trainDate) !== snapshot.serviceDate) return [];
    const observed = boardTime(row, stop);
    const planned = scheduled(stop);
    if (observed === null || planned === null) return [];
    const difference = Math.abs(Date.parse(observed) - Date.parse(planned));
    if (difference > 6 * 60_000) return [];
    const originMatch = nameMatches(row.origin, origin);
    const destinationMatch = nameMatches(row.destination, destination);
    if (!originMatch && !destinationMatch) return [];
    return [{ row, score: difference + (originMatch ? 0 : 60_000) + (destinationMatch ? 0 : 60_000) }];
  }).sort((left, right) => left.score - right.score);
  if (scored.length === 0) return null;
  if (scored.length > 1 && scored[0]!.score === scored[1]!.score
    && scored[0]!.row.trainCode !== scored[1]!.row.trainCode) return null;
  return scored[0]!.row;
}

function movementForStop(stop: StopSnapshot, movements: IrishRailMovement[]): IrishRailMovement | null {
  const passengerCalls = movements.filter((movement) => movement.locationType !== "T");
  const named = passengerCalls.filter((movement) =>
    movement.locationType !== "T" && nameMatches(movement.locationName, stop.stationName)
  );
  const candidates = (named.length > 0 ? named : passengerCalls).map((movement) => {
    const clock = stop.scheduledDeparture === null ? movement.scheduledArrival : movement.scheduledDeparture;
    const time = clockNear(clock, scheduled(stop));
    return {
      movement,
      difference: time === null || scheduled(stop) === null
        ? Number.POSITIVE_INFINITY
        : Math.abs(Date.parse(time) - Date.parse(scheduled(stop)!)),
    };
  }).filter((candidate) => candidate.difference <= 6 * 60_000)
    .sort((left, right) => left.difference - right.difference);
  if (candidates.length === 0) return null;
  if (candidates.length > 1 && candidates[0]!.difference === candidates[1]!.difference) return null;
  return candidates[0]!.movement;
}

export function irishRailObservations(
  snapshot: TripSnapshot,
  movements: IrishRailMovement[],
  status: string,
  observedAt: string,
): PlatformObservation[] {
  const wholeTripCancelled = /cancel/iu.test(status);
  return snapshot.stops.flatMap((stop): PlatformObservation[] => {
    if (stop.countryCode !== "IE") return [];
    const movement = movementForStop(stop, movements);
    if (movement === null && !wholeTripCancelled) return [];
    const expectedArrival = movement === null ? null : clockNear(movement.expectedArrival, stop.scheduledArrival);
    const expectedDeparture = movement === null ? null : clockNear(movement.expectedDeparture, stop.scheduledDeparture);
    if (expectedArrival === null && expectedDeparture === null && !wholeTripCancelled) return [];
    return [{
      stopSequence: stop.sequence,
      stationId: stop.stationId,
      ...(expectedArrival === null ? {} : { expectedArrival }),
      ...(expectedDeparture === null ? {} : { expectedDeparture }),
      ...(wholeTripCancelled ? { cancelled: true } : {}),
      observedAt,
      source: "Irish Rail Realtime API",
    }];
  });
}
