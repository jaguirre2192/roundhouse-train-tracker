import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import type { PlatformObservation } from "./platform-overlay.js";
import type {
  TranslinkNIInfo,
  TranslinkNIJourney,
  TranslinkNILeg,
  TranslinkNILocation,
  TranslinkNITripResponse,
} from "./translink-ni-api-models.js";

export interface TranslinkNIMatch {
  journey: TranslinkNIJourney;
  leg: TranslinkNILeg;
}

export interface TranslinkNIEnrichment {
  observations: PlatformObservation[];
  alertIds: string[];
}

function normalized(value: string): string {
  return value.normalize("NFKD")
    .replace(/\p{Diacritic}/gu, "")
    .replace(/\bbelfast great central\b/giu, "belfast grand central")
    .replace(/\b(?:railway|rail|train|station|stn)\b/giu, " ")
    .replace(/[^\p{Letter}\p{Number}]+/gu, " ")
    .trim()
    .toLowerCase();
}

export function translinkNIStationSearchName(value: string): string {
  return value.replace(/\bbelfast great central(?: railway)? station\b/giu, "Belfast Grand Central");
}

function nameScore(left: string, right: string): number {
  const first = normalized(left);
  const second = normalized(right);
  if (first.length === 0 || second.length === 0) return 0;
  if (first === second) return 100;
  const shorter = first.length < second.length ? first : second;
  const longer = first.length < second.length ? second : first;
  if (shorter.length >= 4 && longer.includes(shorter)) return 75;
  const firstTokens = new Set(first.split(" "));
  const secondTokens = new Set(second.split(" "));
  const common = [...firstTokens].filter((token) => token.length >= 3 && secondTokens.has(token));
  return common.length >= 2 ? 40 + common.length : 0;
}

export function translinkNITrip(snapshot: TripSnapshot): boolean {
  const identity = normalized(`${snapshot.nativeId} ${snapshot.operatorName} ${snapshot.product}`);
  return identity.includes("gb northern ireland")
    || identity.includes("translink")
    || identity.includes("northern ireland")
    || identity.includes("nir")
    || identity.includes("enterprise");
}

function coordinate(location: TranslinkNILocation): { latitude: number; longitude: number } | null {
  const [latitude, longitude] = location.coord ?? [];
  if (latitude === undefined || longitude === undefined
    || !Number.isFinite(latitude) || !Number.isFinite(longitude)) return null;
  return { latitude, longitude };
}

function distanceKilometers(stop: StopSnapshot, location: TranslinkNILocation): number | null {
  const candidate = coordinate(location);
  if (candidate === null || stop.latitude === null || stop.longitude === null) return null;
  const radians = (degrees: number) => degrees * Math.PI / 180;
  const latitudeDelta = radians(candidate.latitude - stop.latitude);
  const longitudeDelta = radians(candidate.longitude - stop.longitude);
  const firstLatitude = radians(stop.latitude);
  const secondLatitude = radians(candidate.latitude);
  const value = Math.sin(latitudeDelta / 2) ** 2
    + Math.cos(firstLatitude) * Math.cos(secondLatitude) * Math.sin(longitudeDelta / 2) ** 2;
  return 6_371 * 2 * Math.atan2(Math.sqrt(value), Math.sqrt(1 - value));
}

function stationScore(stop: StopSnapshot, location: TranslinkNILocation): number {
  if (location.type !== "stop" || location.productClasses?.includes(0) !== true) return 0;
  const score = nameScore(stop.stationName, location.name);
  if (score === 0) return 0;
  const distance = distanceKilometers(stop, location);
  if (distance !== null && distance > 30) return 0;
  if (distance === null) return score;
  if (distance <= 0.75) return score + 30;
  if (distance <= 3) return score + 20;
  if (distance <= 10) return score + 5;
  return score;
}

export function selectTranslinkNIStation(
  stop: StopSnapshot,
  locations: TranslinkNILocation[],
): TranslinkNILocation | null {
  const ranked = locations.map((location) => ({ location, score: stationScore(stop, location) }))
    .filter((candidate) => candidate.score > 0)
    .sort((left, right) => right.score - left.score);
  if (ranked.length === 0) return null;
  if (ranked.length > 1 && ranked[0]!.score === ranked[1]!.score
    && ranked[0]!.location.id !== ranked[1]!.location.id) return null;
  return ranked[0]!.location;
}

function timestamp(value: string | null | undefined): number | null {
  if (value === null || value === undefined || value.trim().length === 0) return null;
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? null : parsed;
}

function iso(value: string | null | undefined): string | undefined {
  const parsed = timestamp(value);
  return parsed === null ? undefined : new Date(parsed).toISOString();
}

function timeDifference(stop: StopSnapshot, location: TranslinkNILocation): number {
  const expected = [stop.scheduledDeparture, stop.scheduledArrival]
    .flatMap((value) => {
      const parsed = timestamp(value);
      return parsed === null ? [] : [parsed];
    });
  const candidates = [location.departureTimePlanned, location.arrivalTimePlanned]
    .flatMap((value) => {
      const parsed = timestamp(value);
      return parsed === null ? [] : [parsed];
    });
  if (expected.length === 0 || candidates.length === 0) return Number.POSITIVE_INFINITY;
  return Math.min(...expected.flatMap((planned) => candidates.map((actual) => Math.abs(actual - planned))));
}

function railLeg(leg: TranslinkNILeg): boolean {
  if (leg.transportation.product?.class !== 0) return false;
  const operator = normalized(`${leg.transportation.operator?.id ?? ""} ${leg.transportation.operator?.name ?? ""}`);
  return operator.includes("railni") || operator.includes("nirail") || operator.includes("translink");
}

export function matchTranslinkNIJourney(
  snapshot: TripSnapshot,
  origin: StopSnapshot,
  destination: StopSnapshot,
  response: TranslinkNITripResponse,
): TranslinkNIMatch | null {
  const candidates = (response.journeys ?? []).flatMap((journey) => (journey.legs ?? [])
    .filter(railLeg)
    .map((leg) => {
      const difference = timeDifference(origin, leg.origin);
      const originMatch = nameScore(origin.stationName, leg.origin.name);
      const destinationMatch = Math.max(
        nameScore(destination.stationName, leg.destination.name),
        nameScore(snapshot.headsign, leg.transportation.destination?.name ?? ""),
      );
      const score = originMatch + destinationMatch + (journey.interchanges === 0 ? 20 : 0);
      return { journey, leg, difference, score };
    }))
    .filter((candidate) => candidate.difference <= 15 * 60_000 && candidate.score >= 150)
    .sort((left, right) => right.score - left.score || left.difference - right.difference);
  if (candidates.length === 0) return null;
  if (candidates.length > 1 && candidates[0]!.score === candidates[1]!.score
    && candidates[0]!.difference === candidates[1]!.difference
    && candidates[0]!.leg.transportation.id !== candidates[1]!.leg.transportation.id) return null;
  return { journey: candidates[0]!.journey, leg: candidates[0]!.leg };
}

function recordProperty(properties: Record<string, unknown> | undefined, name: string): string | undefined {
  const value = properties?.[name];
  if (typeof value === "string" && value.trim().length > 0) return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return undefined;
}

function property(location: TranslinkNILocation, name: string): string | undefined {
  return recordProperty(location.properties, name);
}

function cancellationText(value: unknown): boolean {
  if (typeof value === "string") {
    const status = normalized(value);
    return status.includes("cancel") || status.includes("skip") || status.includes("deleted")
      || status.includes("not serviced");
  }
  if (Array.isArray(value)) return value.some(cancellationText);
  return false;
}

function propertyCancellation(properties: Record<string, unknown> | undefined): boolean {
  return Object.entries(properties ?? {}).some(([key, value]) => {
    const normalizedKey = normalized(key);
    if (normalizedKey.includes("cancel") || normalizedKey.includes("skip")) {
      return value === true || value === 1 || value === "1" || normalized(String(value)) === "yes";
    }
    return cancellationText(value);
  });
}

function cancelled(value: Pick<TranslinkNILocation | TranslinkNILeg, "realtimeStatus" | "properties">): boolean {
  return cancellationText(value.realtimeStatus) || propertyCancellation(value.properties);
}

function pointForStop(stop: StopSnapshot, points: TranslinkNILocation[]): TranslinkNILocation | null {
  const ranked = points.map((point) => ({
    point,
    score: nameScore(stop.stationName, point.name),
    difference: timeDifference(stop, point),
  })).filter((candidate) => candidate.score > 0 && candidate.difference <= 15 * 60_000)
    .sort((left, right) => right.score - left.score || left.difference - right.difference);
  if (ranked.length === 0) return null;
  if (ranked.length > 1 && ranked[0]!.score === ranked[1]!.score
    && ranked[0]!.difference === ranked[1]!.difference
    && ranked[0]!.point.id !== ranked[1]!.point.id) return null;
  return ranked[0]!.point;
}

function fnv1a(value: string): string {
  let hash = 0x811c9dc5;
  for (const character of value) {
    hash ^= character.codePointAt(0) ?? 0;
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, "0");
}

function infoIdentity(info: TranslinkNIInfo): string | null {
  if (info.id !== undefined && info.id.trim().length > 0) {
    return `${info.id.trim()}:${info.version ?? 0}`;
  }
  const content = (info.infoLinks ?? [])
    .flatMap((link) => [link.title, link.subtitle, link.urlText, link.content])
    .filter((value): value is string => value !== undefined && value.trim().length > 0)
    .join("|");
  return content.length === 0 ? null : fnv1a(normalized(content));
}

function alertIds(match: TranslinkNIMatch): string[] {
  const points = match.leg.stopSequence ?? [];
  const infos = [
    ...(match.journey.infos ?? []),
    ...(match.leg.infos ?? []),
    ...points.flatMap((point) => point.infos ?? []),
  ];
  const train = recordProperty(match.leg.transportation.properties, "trainNumber")
    ?? match.leg.transportation.id;
  return [...new Set(infos.flatMap((info) => {
    const identity = infoIdentity(info);
    return identity === null ? [] : [`translink-ni:${train}:${identity}`];
  }))];
}

export function translinkNIEnrichment(
  snapshot: TripSnapshot,
  match: TranslinkNIMatch,
  observedAt: string,
): TranslinkNIEnrichment {
  const points = match.leg.stopSequence ?? [match.leg.origin, match.leg.destination];
  const wholeCancelled = cancelled(match.leg);
  const cancellationKnown = match.leg.isRealtimeControlled !== undefined
    || (match.leg.realtimeStatus?.length ?? 0) > 0;
  const observations = snapshot.stops.flatMap((stop): PlatformObservation[] => {
    const point = pointForStop(stop, points);
    if (point === null) return [];
    const plannedPlatform = property(point, "stoppingPointPlanned");
    const expectedPlatform = property(point, "platform") ?? property(point, "platformName");
    const expectedArrival = iso(point.arrivalTimeEstimated);
    const expectedDeparture = iso(point.departureTimeEstimated);
    const pointCancelled = wholeCancelled || cancelled(point);
    const hasCancellationState = pointCancelled || cancellationKnown
      || (point.realtimeStatus?.length ?? 0) > 0;
    if (plannedPlatform === undefined && expectedPlatform === undefined
      && expectedArrival === undefined && expectedDeparture === undefined && !hasCancellationState) return [];
    return [{
      stopSequence: stop.sequence,
      stationId: stop.stationId,
      ...(plannedPlatform === undefined ? {} : { plannedPlatform }),
      ...(expectedPlatform === undefined ? {} : { expectedPlatform }),
      ...(expectedArrival === undefined ? {} : { expectedArrival }),
      ...(expectedDeparture === undefined ? {} : { expectedDeparture }),
      ...(hasCancellationState ? { cancelled: pointCancelled } : {}),
      observedAt,
      source: "Translink NI Opendata API",
    }];
  });
  return { observations, alertIds: alertIds(match) };
}
