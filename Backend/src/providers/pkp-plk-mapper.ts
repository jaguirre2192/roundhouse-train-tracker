import { needsRealtimeUpdate } from "./realtime-stop-candidates.js";
import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import type { PlatformObservation } from "./platform-overlay.js";
import type {
  PLKDisruption,
  PLKOperation,
  PLKRoute,
  PLKRouteStop,
  PLKScheduleResponse,
  PLKStation,
} from "./pkp-plk-types.js";
import { zonedWallClockToUTC } from "./zoned-time.js";

function normalized(value: string): string {
  return value.normalize("NFKD")
    .replace(/\p{Diacritic}/gu, "")
    .replace(/\b(?:dworzec|stacja)\b/giu, " ")
    .replace(/[^\p{Letter}\p{Number}]+/gu, " ")
    .trim()
    .toLowerCase();
}

function clean(value: string | null | undefined): string | null {
  const result = value?.trim();
  return result === undefined || result.length === 0 ? null : result;
}

function platformTrack(platform: string | null | undefined, track: string | null | undefined): string | null {
  const cleanedPlatform = clean(platform);
  const cleanedTrack = clean(track);
  if (cleanedPlatform === null) return cleanedTrack;
  if (cleanedTrack === null) return cleanedPlatform;
  return `${cleanedPlatform}/${cleanedTrack}`;
}

function numbers(value: string | null | undefined): string[] {
  return value?.match(/\d+/gu) ?? [];
}

function localWarsawISO(
  year: number,
  month: number,
  day: number,
  hour: number,
  minute: number,
  second: number,
): string {
  return new Date(zonedWallClockToUTC("Europe/Warsaw", year, month, day, hour, minute, second)).toISOString();
}

function durationParts(value: string | null | undefined): [number, number, number] | null {
  if (value === null || value === undefined) return null;
  const clock = value.match(/^(\d{1,2}):(\d{2}):(\d{2})(?:\.\d+)?$/u);
  if (clock !== null) return [Number(clock[1]), Number(clock[2]), Number(clock[3])];
  const iso = value.match(/^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?$/u);
  if (iso === null) return null;
  return [Number(iso[1] ?? 0), Number(iso[2] ?? 0), Math.trunc(Number(iso[3] ?? 0))];
}

function scheduledISO(date: string, dayOffset: number | null | undefined, time: string | null | undefined): string | null {
  const dateMatch = date.match(/^(\d{4})-(\d{2})-(\d{2})$/u);
  const duration = durationParts(time);
  if (dateMatch === null || duration === null) return null;
  const localDay = new Date(Date.UTC(
    Number(dateMatch[1]),
    Number(dateMatch[2]) - 1,
    Number(dateMatch[3]) + (dayOffset ?? 0),
  ));
  return localWarsawISO(
    localDay.getUTCFullYear(),
    localDay.getUTCMonth() + 1,
    localDay.getUTCDate(),
    duration[0],
    duration[1],
    duration[2],
  );
}

export function parsePLKDateTime(value: string | null | undefined): string | null {
  if (value === null || value === undefined) return null;
  if (/[zZ]$|[+-]\d{2}:?\d{2}$/u.test(value)) {
    const parsed = Date.parse(value);
    return Number.isNaN(parsed) ? null : new Date(parsed).toISOString();
  }
  const match = value.match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/u);
  return match === null ? null : localWarsawISO(
    Number(match[1]), Number(match[2]), Number(match[3]),
    Number(match[4]), Number(match[5]), Number(match[6]),
  );
}

function delayedTime(
  actual: string | null | undefined,
  planned: string | null | undefined,
  delayMinutes: number | null | undefined,
): string | null {
  const actualISO = parsePLKDateTime(actual);
  if (actualISO !== null) return actualISO;
  const plannedISO = parsePLKDateTime(planned);
  if (plannedISO === null || delayMinutes === null || delayMinutes === undefined) return null;
  return new Date(Date.parse(plannedISO) + delayMinutes * 60_000).toISOString();
}

function stopPlannedTime(routeStop: PLKRouteStop, stop: StopSnapshot, operatingDate: string): string | null {
  return stop.scheduledDeparture !== null
    ? scheduledISO(operatingDate, routeStop.departureDay, routeStop.departureTime)
    : scheduledISO(operatingDate, routeStop.arrivalDay, routeStop.arrivalTime);
}

function routeStopFor(stop: StopSnapshot, route: PLKRoute, stations: Map<number, string>): PLKRouteStop | null {
  const requested = normalized(stop.stationName);
  const exact = (route.stations ?? []).filter((candidate) => {
    const name = stations.get(candidate.stationId) ?? null;
    return name !== null && normalized(name) === requested;
  });
  return exact.length === 1 ? exact[0]! : null;
}

function identityScore(snapshot: TripSnapshot, route: PLKRoute): number {
  const routeValues = [
    route.name,
    route.nationalNumber,
    route.internationalArrivalNumber,
    route.internationalDepartureNumber,
    ...(route.stations ?? []).flatMap((stop) => [stop.arrivalTrainNumber, stop.departureTrainNumber]),
  ];
  const product = normalized(snapshot.product);
  const exact = routeValues.some((value) => value !== null && value !== undefined && normalized(value) === product);
  const productNumbers = new Set(numbers(snapshot.product));
  const numberMatch = routeValues.some((value) => numbers(value).some((number) => productNumbers.has(number)));
  const category = normalized(route.commercialCategorySymbol ?? "");
  return (exact ? 40 : 0) + (numberMatch ? 30 : 0) + (category.length > 0 && product.includes(category) ? 5 : 0);
}

export interface MatchedPLKRoute {
  route: PLKRoute;
  stations: Map<number, string>;
}

export function plkAnchorStationIDs(stations: PLKStation[], stops: StopSnapshot[]): number[] {
  const stationMap = new Map(stations.flatMap((station) => station.name === null
    ? [] : [[normalized(station.name), station.id] as const]));
  const firstId = stationMap.get(normalized(stops[0]?.stationName ?? ""));
  const lastId = stationMap.get(normalized(stops.at(-1)?.stationName ?? ""));
  return [...new Set([firstId, lastId].filter((value): value is number => value !== undefined))];
}

export function matchingPLKRoute(
  snapshot: TripSnapshot,
  response: PLKScheduleResponse,
  operatingDate: string,
): MatchedPLKRoute | null {
  const stations = new Map(Object.values(response.dictionaries?.stations ?? {}).flatMap((station) =>
    station.name === null ? [] : [[station.id, station.name] as const]));
  const candidates = (response.routes ?? []).filter((route) => (route.operatingDates ?? []).includes(operatingDate))
    .map((route) => {
      let timeHits = 0;
      let stationHits = 0;
      for (const stop of snapshot.stops.filter((candidate) => candidate.countryCode === "PL")) {
        const routeStop = routeStopFor(stop, route, stations);
        if (routeStop === null) continue;
        stationHits += 1;
        const scheduled = stop.scheduledDeparture ?? stop.scheduledArrival;
        const planned = stopPlannedTime(routeStop, stop, operatingDate);
        if (scheduled !== null && planned !== null
          && Math.abs(Date.parse(scheduled) - Date.parse(planned)) <= 10 * 60_000) timeHits += 1;
      }
      const score = identityScore(snapshot, route) + Math.min(stationHits, 3) * 3 + Math.min(timeHits, 3) * 15;
      return { route, score, timeHits };
    })
    .filter((candidate) => candidate.timeHits > 0)
    .sort((left, right) => right.score - left.score);
  if (candidates.length === 0) return null;
  if (candidates.length > 1 && candidates[0]!.score === candidates[1]!.score) return null;
  return { route: candidates[0]!.route, stations };
}

export function matchingPLKOperation(
  route: PLKRoute,
  operatingDate: string,
  operations: PLKOperation[],
): PLKOperation | null {
  return operations.find((candidate) => candidate.operatingDate === operatingDate
    && candidate.scheduleId === route.scheduleId
    && (candidate.orderId === route.orderId
      || (route.trainOrderId !== null && route.trainOrderId !== undefined
        && candidate.trainOrderId === route.trainOrderId))) ?? null;
}

function relevantDisruption(disruption: PLKDisruption, route: PLKRoute, operatingDate: string): boolean {
  const stationIds = new Set((route.stations ?? []).map((stop) => stop.stationId));
  if (disruption.startStationId !== null && disruption.startStationId !== undefined
    && stationIds.has(disruption.startStationId)) return true;
  if (disruption.endStationId !== null && disruption.endStationId !== undefined
    && stationIds.has(disruption.endStationId)) return true;
  return (disruption.affectedRoutes ?? []).some((affected) => affected.operatingDate === operatingDate
    && affected.scheduleId === route.scheduleId
    && (affected.orderId === route.orderId
      || (route.trainOrderId !== null && route.trainOrderId !== undefined
        && affected.trainOrderId === route.trainOrderId)));
}

export function projectPLKRealtime(
  snapshot: TripSnapshot,
  matched: MatchedPLKRoute,
  operation: PLKOperation | null,
  disruptions: PLKDisruption[],
  observedAt: string,
  source: string,
): { observations: PlatformObservation[]; alertIds: string[] } {
  const operationStops = new Map((operation?.stations ?? []).map((stop) => [stop.stationId, stop]));
  const observations = snapshot.stops.filter((stop) => stop.countryCode === "PL" && needsRealtimeUpdate(stop, snapshot))
    .flatMap((stop): PlatformObservation[] => {
      const routeStop = routeStopFor(stop, matched.route, matched.stations);
      if (routeStop === null) return [];
      const operationStop = operationStops.get(routeStop.stationId);
      const departure = stop.scheduledDeparture !== null;
      const publishedPlatform = departure
        ? platformTrack(routeStop.departurePlatform, routeStop.departureTrack)
        : platformTrack(routeStop.arrivalPlatform, routeStop.arrivalTrack);
      const plannedPlatform = stop.plannedPlatform ?? publishedPlatform;
      const expectedArrival = stop.scheduledArrival === null ? null : delayedTime(
        operationStop?.actualArrival,
        operationStop?.plannedArrival,
        operationStop?.arrivalDelayMinutes,
      );
      const expectedDeparture = stop.scheduledDeparture === null ? null : delayedTime(
        operationStop?.actualDeparture,
        operationStop?.plannedDeparture,
        operationStop?.departureDelayMinutes,
      );
      const cancelled = operation === null
        ? undefined
        : operation.trainStatus === "X" || operationStop?.isCancelled === true;
      if (publishedPlatform === null && expectedArrival === null
        && expectedDeparture === null && cancelled === undefined) return [];
      return [{
        stopSequence: stop.sequence,
        stationId: stop.stationId,
        plannedPlatform,
        expectedPlatform: publishedPlatform,
        ...(expectedArrival === null ? {} : { expectedArrival }),
        ...(expectedDeparture === null ? {} : { expectedDeparture }),
        ...(cancelled === undefined ? {} : { cancelled }),
        observedAt,
        source,
      }];
    });
  const alertIds = disruptions
    .filter((disruption) => relevantDisruption(disruption, matched.route, snapshot.serviceDate))
    .map((disruption) => `pkp-plk:${disruption.disruptionId}`);
  return { observations, alertIds: [...new Set(alertIds)] };
}
