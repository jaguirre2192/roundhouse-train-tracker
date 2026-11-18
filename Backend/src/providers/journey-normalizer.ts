import { createHash } from "node:crypto";
import type {
  JourneyBadge,
  JourneyCallSnapshot,
  JourneyOptionSnapshot,
  JourneySegmentSnapshot,
  RailJourneySegmentSnapshot,
  RailPlaceKind,
  RailPlaceSnapshot,
  WalkJourneySegmentSnapshot,
} from "../domain/journey.js";
import { journeyMainlinePolicy } from "./journey-mainline-policy.js";
import { encodeRailPlaceId } from "./rail-place-id.js";
import { publishedAmtrakName } from "./transitous-amtrak-name.js";
import { transitousServiceDate } from "./transitous-service-date.js";
import { transitousPlaceCountryCode } from "./transitous-country.js";
import type {
  TransitousJourneyPlace,
  TransitousLeg,
  TransitousPlanResponse,
} from "./transitous-journey-types.js";

const maximumWalkDuration = 30 * 60;
const maximumWalkDistance = 5_000;

export interface JourneyNormalizationContext {
  originKind: RailPlaceKind;
  destinationKind: RailPlaceKind;
  fetchedAt: string;
  attributions: string[];
}

interface NormalizedRailLeg {
  kind: "rail";
  segment: RailJourneySegmentSnapshot;
  startTime: string;
  endTime: string;
}

interface NormalizedWalkLeg {
  kind: "walk";
  segment: WalkJourneySegmentSnapshot;
  startTime: string;
  endTime: string;
  fromParentId: string | null;
  toParentId: string | null;
}

interface ProhibitedLeg {
  kind: "prohibited";
}

type NormalizedLeg = NormalizedRailLeg | NormalizedWalkLeg;
type ClassifiedLeg = NormalizedLeg | ProhibitedLeg;

function text(value: string | null | undefined): string | null {
  const result = value?.trim();
  return result === undefined || result.length === 0 ? null : result;
}

function eligibleMode(mode: string): string[] {
  switch (mode.trim().toUpperCase()) {
    case "HIGHSPEED_RAIL": return ["highSpeedRail"];
    case "LONG_DISTANCE": return ["longDistanceRail"];
    case "NIGHT_RAIL": return ["nightRail"];
    case "REGIONAL_RAIL": return ["regionalRail"];
    default: return [];
  }
}

function canonicalPlaceId(place: TransitousJourneyPlace): string {
  const nativeId = text(place.stopId) ?? `coord:${place.lat.toFixed(6)},${place.lon.toFixed(6)}`;
  return encodeRailPlaceId({
    provider: "transitous",
    kind: "station",
    nativeId,
    countryCode: transitousPlaceCountryCode(place),
    latitude: null,
    longitude: null,
  });
}

function railPlace(
  place: TransitousJourneyPlace,
  mode: string,
  attributions: string[],
): RailPlaceSnapshot {
  const country = transitousPlaceCountryCode(place);
  return {
    id: canonicalPlaceId(place),
    kind: "station",
    displayName: place.name,
    context: text(place.tz) ?? country,
    countryCode: country,
    timeZoneIdentifier: text(place.tz) ?? "UTC",
    location: { latitude: place.lat, longitude: place.lon },
    eligibleModes: eligibleMode(mode),
    attributions,
  };
}

function call(
  place: TransitousJourneyPlace,
  leg: TransitousLeg,
  position: "from" | "intermediate" | "to",
  attributions: string[],
): JourneyCallSnapshot {
  const scheduledArrival = text(place.scheduledArrival)
    ?? (position === "to" ? text(leg.scheduledEndTime) : null);
  const scheduledDeparture = text(place.scheduledDeparture)
    ?? (position === "from" ? text(leg.scheduledStartTime) : null);
  return {
    place: railPlace(place, leg.mode, attributions),
    city: null,
    scheduledArrival,
    scheduledDeparture,
    expectedArrival: text(place.arrival)
      ?? (position === "to" ? text(leg.endTime) ?? scheduledArrival : null),
    expectedDeparture: text(place.departure)
      ?? (position === "from" ? text(leg.startTime) ?? scheduledDeparture : null),
    plannedPlatform: text(place.scheduledTrack),
    expectedPlatform: text(place.track),
    isCancelled: place.cancelled === true,
  };
}

function duration(leg: TransitousLeg): number {
  if (leg.duration !== null && leg.duration !== undefined && Number.isFinite(leg.duration)) return leg.duration;
  return (Date.parse(leg.endTime) - Date.parse(leg.startTime)) / 1_000;
}

function product(leg: TransitousLeg): string {
  const names = [text(leg.routeShortName), text(leg.tripShortName)].filter((value) => value !== null);
  return publishedAmtrakName(leg) ?? text(leg.displayName) ?? (names.length > 0 ? names.join(" ") : leg.mode.replaceAll("_", " ").toLowerCase());
}

function classifyLeg(leg: TransitousLeg, context: JourneyNormalizationContext): ClassifiedLeg {
  const classification = journeyMainlinePolicy.classify(leg);
  if (classification === "prohibited") return { kind: "prohibited" };
  if (classification === "walk") {
    const from = railPlace(leg.from, leg.mode, context.attributions);
    const to = railPlace(leg.to, leg.mode, context.attributions);
    return {
      kind: "walk",
      segment: {
        from,
        to,
        duration: duration(leg),
        distance: leg.distance === null || leg.distance === undefined ? null : leg.distance,
        isStationChange: from.id !== to.id,
      },
      startTime: leg.startTime,
      endTime: leg.endTime,
      fromParentId: text(leg.from.parentId),
      toParentId: text(leg.to.parentId),
    };
  }

  const nativeTripId = text(leg.tripId);
  const tripId = nativeTripId === null ? null : `eu:transitous:${nativeTripId}`;
  const from = call(leg.from, leg, "from", context.attributions);
  const to = call(leg.to, leg, "to", context.attributions);
  const intermediateCalls = (leg.intermediateStops ?? []).map((place) =>
    call(place, leg, "intermediate", context.attributions));
  return {
    kind: "rail",
    segment: {
      tripId,
      serviceDate: transitousServiceDate(nativeTripId, {
        scheduledDeparture: from.scheduledDeparture,
        departure: from.expectedDeparture,
        tz: leg.from.tz,
      }, leg.startTime),
      operatorName: text(leg.agencyName) ?? "Rail operator",
      product: product(leg),
      trainNumber: text(leg.tripShortName),
      trainName: publishedAmtrakName(leg) ?? text(leg.displayName),
      from,
      to,
      intermediateCalls,
      isCancelled: leg.cancelled === true
        || from.isCancelled
        || to.isCancelled
        || intermediateCalls.some((candidate) => candidate.isCancelled),
      isRealtime: leg.realTime === true,
      isTrackable: tripId !== null,
      untrackableReason: tripId === null ? "No stable train identity" : null,
    },
    startTime: leg.startTime,
    endTime: leg.endTime,
  };
}

function isBoundedWalk(leg: NormalizedWalkLeg): boolean {
  return Number.isFinite(leg.segment.duration)
    && leg.segment.duration >= 0
    && leg.segment.duration <= maximumWalkDuration
    && (leg.segment.distance === null
      || (Number.isFinite(leg.segment.distance)
        && leg.segment.distance >= 0
        && leg.segment.distance <= maximumWalkDistance));
}

function removeCityAccessAndEgress(
  legs: NormalizedLeg[],
  context: JourneyNormalizationContext,
): NormalizedLeg[] {
  let first = 0;
  let last = legs.length;
  const initial = legs[first];
  if (context.originKind === "city" && initial?.kind === "walk" && isBoundedWalk(initial)) first += 1;
  const final = legs[last - 1];
  if (context.destinationKind === "city" && final?.kind === "walk" && isBoundedWalk(final)) last -= 1;
  return legs.slice(first, last);
}

function distanceInMeters(from: RailPlaceSnapshot, to: RailPlaceSnapshot): number {
  const radians = (degrees: number) => degrees * Math.PI / 180;
  const latitudeDelta = radians(to.location.latitude - from.location.latitude);
  const longitudeDelta = radians(to.location.longitude - from.location.longitude);
  const fromLatitude = radians(from.location.latitude);
  const toLatitude = radians(to.location.latitude);
  const value = Math.sin(latitudeDelta / 2) ** 2
    + Math.cos(fromLatitude) * Math.cos(toLatitude) * Math.sin(longitudeDelta / 2) ** 2;
  return 6_371_000 * 2 * Math.atan2(Math.sqrt(value), Math.sqrt(1 - value));
}

function isAliasWalk(leg: NormalizedWalkLeg): boolean {
  if (leg.segment.distance !== 0) return false;
  if (leg.segment.from.id === leg.segment.to.id) return true;
  if (leg.fromParentId !== null && leg.fromParentId === leg.toParentId) return true;
  return distanceInMeters(leg.segment.from, leg.segment.to) <= 25;
}

function collapseAliases(legs: NormalizedLeg[]): NormalizedLeg[] {
  return legs.filter((leg) => leg.kind !== "walk" || !isAliasWalk(leg));
}

function mergeCalls(arrival: JourneyCallSnapshot, departure: JourneyCallSnapshot): JourneyCallSnapshot {
  return {
    place: arrival.place,
    city: arrival.city ?? departure.city,
    scheduledArrival: arrival.scheduledArrival,
    scheduledDeparture: departure.scheduledDeparture,
    expectedArrival: arrival.expectedArrival,
    expectedDeparture: departure.expectedDeparture,
    plannedPlatform: departure.plannedPlatform ?? arrival.plannedPlatform,
    expectedPlatform: departure.expectedPlatform ?? arrival.expectedPlatform,
    isCancelled: arrival.isCancelled || departure.isCancelled,
  };
}

function mergeSameServiceRail(legs: NormalizedLeg[]): NormalizedLeg[] {
  const merged: NormalizedLeg[] = [];
  for (const leg of legs) {
    const previous = merged.at(-1);
    if (leg.kind !== "rail" || previous?.kind !== "rail" || leg.segment.tripId === null
      || previous.segment.tripId !== leg.segment.tripId) {
      merged.push(leg);
      continue;
    }
    const connection = mergeCalls(previous.segment.to, leg.segment.from);
    merged[merged.length - 1] = {
      kind: "rail",
      startTime: previous.startTime,
      endTime: leg.endTime,
      segment: {
        ...previous.segment,
        to: leg.segment.to,
        intermediateCalls: [
          ...previous.segment.intermediateCalls,
          connection,
          ...leg.segment.intermediateCalls,
        ],
        isCancelled: previous.segment.isCancelled || leg.segment.isCancelled,
        isRealtime: previous.segment.isRealtime || leg.segment.isRealtime,
      },
    };
  }
  return merged;
}

function hasValidTransferWalks(legs: NormalizedLeg[]): boolean {
  return legs.every((leg, index) => leg.kind !== "walk"
    || (index > 0
      && index < legs.length - 1
      && legs[index - 1]?.kind === "rail"
      && legs[index + 1]?.kind === "rail"
      && isBoundedWalk(leg)));
}

function hash(value: unknown): string {
  return createHash("sha256").update(JSON.stringify(value)).digest("hex");
}

function fingerprint(legs: NormalizedLeg[]): string {
  const identity = legs.flatMap((leg) => leg.kind === "rail" ? [{
    tripId: leg.segment.tripId,
    boardingStopId: leg.segment.from.place.id,
    alightingStopId: leg.segment.to.place.id,
    scheduledDeparture: leg.segment.from.scheduledDeparture,
  }] : []);
  return `journey-v1-${hash(identity)}`;
}

function segmentSnapshot(leg: NormalizedLeg, index: number): JourneySegmentSnapshot {
  if (leg.kind === "rail") {
    const id = hash([
      leg.segment.tripId,
      leg.segment.from.place.id,
      leg.segment.to.place.id,
      leg.segment.from.scheduledDeparture,
      index,
    ]).slice(0, 24);
    return { id: `journey-segment-${id}`, kind: "rail", rail: leg.segment, walk: null };
  }
  const id = hash([
    leg.segment.from.id,
    leg.segment.to.id,
    leg.segment.duration,
    leg.segment.distance,
    index,
  ]).slice(0, 24);
  return { id: `journey-segment-${id}`, kind: "walk", rail: null, walk: leg.segment };
}

function option(legs: NormalizedLeg[], context: JourneyNormalizationContext): JourneyOptionSnapshot {
  const railLegs = legs.filter((leg): leg is NormalizedRailLeg => leg.kind === "rail");
  const canonicalFingerprint = fingerprint(legs);
  const startTime = railLegs[0]!.startTime;
  const endTime = railLegs.at(-1)!.endTime;
  const seconds = (Date.parse(endTime) - Date.parse(startTime)) / 1_000;
  return {
    id: `journey-option-${hash(canonicalFingerprint).slice(0, 24)}`,
    fingerprint: canonicalFingerprint,
    startTime,
    endTime,
    duration: seconds,
    transferCount: Math.max(0, railLegs.length - 1),
    segments: legs.map(segmentSnapshot),
    badges: [],
    trackability: {
      trackableRailSegments: railLegs.filter((leg) => leg.segment.isTrackable).length,
      totalRailSegments: railLegs.length,
    },
    realtimeFreshness: railLegs.some((leg) => leg.segment.isRealtime) ? context.fetchedAt : null,
    attributions: [...new Set(context.attributions.map((value) => value.trim()).filter(Boolean))],
    trackingToken: "",
  };
}

function badges(option: JourneyOptionSnapshot, fastest: number, fewestChanges: number): JourneyBadge[] {
  const result: JourneyBadge[] = [];
  if (option.transferCount === 0) result.push("direct");
  if (option.duration === fastest) result.push("fastest");
  if (option.transferCount === fewestChanges) result.push("fewestChanges");
  return result;
}

export function normalizeJourneyOptions(
  payload: TransitousPlanResponse,
  context: JourneyNormalizationContext,
): JourneyOptionSnapshot[] {
  const deduplicated = new Map<string, JourneyOptionSnapshot>();
  for (const itinerary of payload.itineraries) {
    const classified = itinerary.legs.map((leg) => classifyLeg(leg, context));
    if (classified.some((leg) => leg.kind === "prohibited")) continue;
    let legs = removeCityAccessAndEgress(classified as NormalizedLeg[], context);
    legs = collapseAliases(legs);
    legs = mergeSameServiceRail(legs);
    if (!hasValidTransferWalks(legs)) continue;
    if (!legs.some((leg) => leg.kind === "rail")) continue;
    const normalized = option(legs, context);
    if (!deduplicated.has(normalized.fingerprint)) deduplicated.set(normalized.fingerprint, normalized);
  }

  const options = [...deduplicated.values()].sort((left, right) =>
    Date.parse(left.startTime) - Date.parse(right.startTime) || left.fingerprint.localeCompare(right.fingerprint));
  if (options.length === 0) return [];
  const fastest = Math.min(...options.map((value) => value.duration));
  const fewestChanges = Math.min(...options.map((value) => value.transferCount));
  return options.map((value) => ({ ...value, badges: badges(value, fastest, fewestChanges) }));
}
