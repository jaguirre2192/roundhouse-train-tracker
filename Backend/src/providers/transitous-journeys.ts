import { journeyPlanningCountryCodes } from "../domain/journey-coverage.js";
import type { JourneyOptionSnapshot, RailPlaceSnapshot } from "../domain/journey.js";
import type {
  JourneySearchProvider,
  ProviderJourneySearchRequest,
  ProviderJourneySearchResult,
} from "./journey-provider.js";
import { JourneyProviderUnavailableError } from "./journey-provider.js";
import { normalizeJourneyOptions } from "./journey-normalizer.js";
import { isMainlineRailMode, mainlineRailModesParameter } from "./mainline-modes.js";
import { decodeRailPlaceId, encodeRailPlaceId, type DecodedRailPlaceId } from "./rail-place-id.js";
import type {
  TransitousItinerary,
  TransitousJourneyPlace,
  TransitousLeg,
  TransitousPlanResponse,
} from "./transitous-journey-types.js";
import { isTrackableTransitousStation } from "./transitous-mainline-scope.js";
import { isTransitousTimeout, transitousRequestTimeoutMilliseconds } from "./transitous-timeout.js";
import { transitousAPIOrigin, transitousUserAgent } from "./transitous-client.js";
import { transitousPlaceCountryCode } from "./transitous-country.js";
import {
  transitousJourneyEndpointAlias,
  transitousRailwayStationAlias,
  transitousSearchAlias,
} from "./transitous-search-aliases.js";

interface TransitousGeocodeResult {
  type: string;
  name: string;
  id: string;
  lat: number;
  lon: number;
  country?: string | null;
  tz?: string | null;
  category?: string | null;
  modes?: string[] | null;
}

interface PlaceCandidate {
  place: RailPlaceSnapshot;
  providerName: string;
  sourceIndex: number;
  source: TransitousGeocodeResult;
}

const attributions = ["Transitous", "OpenStreetMap contributors"];
const cityStationRadiusMeters = 10_000;
const canonicalCityCoordinateToleranceMeters = 25;
const municipalityCategories = new Set([
  "city",
  "town",
  "place_6",
  "place_8",
  "place_capital_6",
  "place_capital_8",
]);

function isGeocodeResult(value: unknown): value is TransitousGeocodeResult {
  if (typeof value !== "object" || value === null) return false;
  const candidate = value as Record<string, unknown>;
  return typeof candidate.type === "string"
    && typeof candidate.name === "string"
    && typeof candidate.id === "string"
    && typeof candidate.lat === "number"
    && typeof candidate.lon === "number"
    && (candidate.country === undefined || candidate.country === null || typeof candidate.country === "string")
    && (candidate.tz === undefined || candidate.tz === null || typeof candidate.tz === "string")
    && (candidate.category === undefined || candidate.category === null || typeof candidate.category === "string")
    && (candidate.modes === undefined || candidate.modes === null
      || (Array.isArray(candidate.modes) && candidate.modes.every((mode) => typeof mode === "string")));
}

function normalizedText(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const result = value.trim();
  return result.length === 0 ? null : result;
}

function countryCode(value: TransitousGeocodeResult): string | null {
  const country = transitousPlaceCountryCode({ ...value, stopId: value.id });
  return /^[A-Z]{2}$/u.test(country) && country !== "XX" && country !== "EU" ? country : null;
}

function validCoordinate(latitude: number, longitude: number): boolean {
  return Number.isFinite(latitude) && latitude >= -90 && latitude <= 90
    && Number.isFinite(longitude) && longitude >= -180 && longitude <= 180;
}

function acceptedModes(value: TransitousGeocodeResult): string[] {
  return [...new Set((value.modes ?? [])
    .map((mode) => mode.trim().toUpperCase())
    .filter(isMainlineRailMode))];
}

function domainModes(modes: string[]): string[] {
  const names: Record<string, string> = {
    HIGHSPEED_RAIL: "highSpeedRail",
    LONG_DISTANCE: "longDistanceRail",
    NIGHT_RAIL: "nightRail",
    REGIONAL_RAIL: "regionalRail",
  };
  return modes.map((mode) => names[mode]).filter((mode): mode is string => mode !== undefined);
}

function isEligibleStation(nativeId: string, country: string): boolean {
  if (!isTrackableTransitousStation({ id: nativeId, country })) return false;
  const sourceCountry = /^([A-Za-z]{2})-/u.exec(nativeId)?.[1]?.toUpperCase();
  // Transitous also uses a continent-wide feed namespace. Its prefix is not
  // the station's country; accepted modes and the actual country still gate it.
  return sourceCountry === undefined || sourceCountry === "EU"
    || (journeyPlanningCountryCodes.has(sourceCountry)
      && isTrackableTransitousStation({ id: nativeId, country: sourceCountry }));
}

function isAcceptedStop(value: TransitousGeocodeResult): boolean {
  const country = countryCode(value);
  return value.type === "STOP"
    && normalizedText(value.name) !== null
    && normalizedText(value.id) !== null
    && country !== null
    && journeyPlanningCountryCodes.has(country)
    && validCoordinate(value.lat, value.lon)
    && acceptedModes(value).length > 0
    && isEligibleStation(value.id, country);
}

function isMunicipality(value: TransitousGeocodeResult): boolean {
  const category = normalizedText(value.category)?.toLocaleLowerCase("en");
  return category !== undefined && category !== null && municipalityCategories.has(category);
}

function distanceInMeters(left: TransitousGeocodeResult, right: TransitousGeocodeResult): number {
  const radians = (degrees: number) => degrees * Math.PI / 180;
  const latitudeDelta = radians(right.lat - left.lat);
  const longitudeDelta = radians(right.lon - left.lon);
  const leftLatitude = radians(left.lat);
  const rightLatitude = radians(right.lat);
  const haversine = Math.sin(latitudeDelta / 2) ** 2
    + Math.cos(leftLatitude) * Math.cos(rightLatitude) * Math.sin(longitudeDelta / 2) ** 2;
  return 6_371_000 * 2 * Math.atan2(Math.sqrt(haversine), Math.sqrt(1 - haversine));
}

function placeSnapshot(
  value: TransitousGeocodeResult,
  kind: "city" | "station",
  modes: string[],
): RailPlaceSnapshot {
  const country = countryCode(value)!;
  const nativeId = normalizedText(value.id)!;
  const stationAlias = kind === "station" ? transitousRailwayStationAlias(nativeId, country) : undefined;
  const identifier: DecodedRailPlaceId = {
    provider: "transitous",
    kind,
    nativeId: stationAlias?.nativeId ?? nativeId,
    countryCode: country,
    latitude: kind === "city" ? value.lat : null,
    longitude: kind === "city" ? value.lon : null,
  };
  const timeZone = normalizedText(value.tz) ?? "UTC";
  return {
    id: encodeRailPlaceId(identifier),
    kind,
    displayName: value.name.trim(),
    context: timeZone === "UTC" ? country : timeZone,
    countryCode: country,
    timeZoneIdentifier: timeZone,
    location: { latitude: stationAlias?.latitude ?? value.lat, longitude: stationAlias?.longitude ?? value.lon },
    eligibleModes: domainModes(modes),
    attributions: [...attributions],
  };
}

function comparable(value: string): string {
  return value.normalize("NFKD")
    .replaceAll(/\p{M}/gu, "")
    .toLocaleLowerCase("en")
    .replaceAll(/[^\p{L}\p{N}]+/gu, " ")
    .replaceAll(/\bhauptbahnhof\b/gu, "hbf")
    .trim();
}

function rank(candidate: PlaceCandidate, query: string, preferredNativeId?: string): number {
  if (candidate.source.id === preferredNativeId) return -1;
  const name = comparable(candidate.providerName);
  if (candidate.place.kind === "city" && name === query) return 0;
  if (candidate.place.kind === "station" && name === query) return 1;
  if (name.startsWith(query)) return 2;
  if (name.includes(query)) return 3;
  return 4;
}

function containsEveryQueryToken(candidate: PlaceCandidate, query: string): boolean {
  const nameTokens = comparable(candidate.providerName).split(" ");
  return query.split(" ").every((token) => nameTokens.some((nameToken) => nameToken.startsWith(token)));
}

function relevantCandidates(candidates: PlaceCandidate[], query: string): PlaceCandidate[] {
  const exactAnchors = candidates.filter((candidate) => comparable(candidate.providerName) === query);
  return candidates.filter((candidate) => containsEveryQueryToken(candidate, query)
    || (candidate.place.kind === "station" && exactAnchors.some((anchor) =>
      anchor.place.countryCode === candidate.place.countryCode
      && distanceInMeters(anchor.source, candidate.source) <= cityStationRadiusMeters)));
}

function isCanonicalCityDuplicate(candidate: PlaceCandidate, accepted: PlaceCandidate[]): boolean {
  if (candidate.place.kind !== "city") return false;
  const candidateID = normalizedText(candidate.source.id);
  return accepted.some((existing) => {
    if (existing.place.kind !== "city"
      || existing.place.countryCode !== candidate.place.countryCode
      || existing.place.timeZoneIdentifier !== candidate.place.timeZoneIdentifier) return false;
    const existingID = normalizedText(existing.source.id);
    return (candidateID !== null && existingID === candidateID)
      || (comparable(existing.providerName) === comparable(candidate.providerName)
        && distanceInMeters(existing.source, candidate.source) <= canonicalCityCoordinateToleranceMeters);
  });
}

function endpoint(value: DecodedRailPlaceId): string {
  if (value.kind === "station") return value.nativeId;
  if (value.latitude === null || value.longitude === null) throw new Error("Invalid rail place ID");
  return `${value.latitude},${value.longitude}`;
}

function optionalText(value: unknown): boolean {
  return value === undefined || value === null || typeof value === "string";
}

function timestamp(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && Number.isFinite(Date.parse(value));
}

function chronological(start: string, end: string): boolean {
  return Date.parse(start) <= Date.parse(end);
}

function optionalTimestamp(value: unknown): boolean {
  return value === undefined || value === null || timestamp(value);
}

function optionalBoolean(value: unknown): boolean {
  return value === undefined || value === null || typeof value === "boolean";
}

function optionalNonnegativeNumber(value: unknown): boolean {
  return value === undefined || value === null
    || (typeof value === "number" && Number.isFinite(value) && value >= 0);
}

function validJourneyPlace(value: unknown): value is TransitousJourneyPlace {
  if (typeof value !== "object" || value === null) return false;
  const place = value as Record<string, unknown>;
  return typeof place.name === "string" && place.name.trim().length > 0
    && typeof place.lat === "number" && typeof place.lon === "number"
    && validCoordinate(place.lat, place.lon)
    && optionalText(place.stopId) && optionalText(place.parentId) && optionalText(place.tz) && optionalText(place.country)
    && optionalTimestamp(place.arrival) && optionalTimestamp(place.departure)
    && optionalTimestamp(place.scheduledArrival) && optionalTimestamp(place.scheduledDeparture)
    && optionalText(place.scheduledTrack) && optionalText(place.track)
    && optionalBoolean(place.cancelled);
}

function validLeg(value: unknown): value is TransitousLeg {
  if (typeof value !== "object" || value === null) return false;
  const leg = value as Record<string, unknown>;
  const intermediateStops = leg.intermediateStops;
  return typeof leg.mode === "string" && leg.mode.trim().length > 0
    && (leg.routeType === undefined || leg.routeType === null
      || (typeof leg.routeType === "number" && Number.isInteger(leg.routeType)))
    && validJourneyPlace(leg.from) && validJourneyPlace(leg.to)
    && timestamp(leg.startTime) && timestamp(leg.endTime)
    && chronological(leg.startTime, leg.endTime)
    && optionalNonnegativeNumber(leg.duration) && optionalNonnegativeNumber(leg.distance)
    && optionalTimestamp(leg.scheduledStartTime) && optionalTimestamp(leg.scheduledEndTime)
    && optionalBoolean(leg.realTime) && optionalBoolean(leg.cancelled)
    && optionalText(leg.headsign) && optionalText(leg.agencyName) && optionalText(leg.tripId)
    && optionalText(leg.routeShortName) && optionalText(leg.routeLongName)
    && optionalText(leg.tripShortName) && optionalText(leg.displayName)
    && (intermediateStops === undefined || intermediateStops === null
      || (Array.isArray(intermediateStops) && intermediateStops.every(validJourneyPlace)));
}

function validItinerary(value: unknown): value is TransitousItinerary {
  if (typeof value !== "object" || value === null) return false;
  const itinerary = value as Record<string, unknown>;
  return optionalText(itinerary.id)
    && timestamp(itinerary.startTime) && timestamp(itinerary.endTime)
    && chronological(itinerary.startTime, itinerary.endTime)
    && typeof itinerary.duration === "number" && Number.isFinite(itinerary.duration)
    && itinerary.duration >= 0
    && typeof itinerary.transfers === "number" && Number.isInteger(itinerary.transfers)
    && itinerary.transfers >= 0
    && Array.isArray(itinerary.legs) && itinerary.legs.length > 0
    && itinerary.legs.every(validLeg);
}

function validPlanResponse(value: unknown): value is TransitousPlanResponse {
  if (typeof value !== "object" || value === null) return false;
  const candidate = value as Record<string, unknown>;
  return Array.isArray(candidate.itineraries) && candidate.itineraries.every(validItinerary)
    && (candidate.previousPageCursor === undefined || candidate.previousPageCursor === null
      || typeof candidate.previousPageCursor === "string")
    && (candidate.nextPageCursor === undefined || candidate.nextPageCursor === null
      || typeof candidate.nextPageCursor === "string");
}

function nestedPlaces(option: JourneyOptionSnapshot): RailPlaceSnapshot[] {
  return option.segments.flatMap((segment) => segment.kind === "rail"
    ? [
        segment.rail.from.place,
        ...segment.rail.intermediateCalls.map((call) => call.place),
        segment.rail.to.place,
      ]
    : [segment.walk.from, segment.walk.to]);
}

function hasValidNormalizedOptions(options: JourneyOptionSnapshot[]): boolean {
  try {
    return options.every((option) => timestamp(option.startTime) && timestamp(option.endTime)
      && chronological(option.startTime, option.endTime)
      && Number.isFinite(option.duration) && option.duration >= 0)
      && options.flatMap(nestedPlaces).every((place) => {
      const decoded = decodeRailPlaceId(place.id);
      return decoded.kind === place.kind
        && decoded.countryCode === place.countryCode
        && journeyPlanningCountryCodes.has(decoded.countryCode)
        && (decoded.kind !== "station" || isEligibleStation(decoded.nativeId, decoded.countryCode));
    });
  } catch {
    return false;
  }
}

function assertEligibleEndpoint(value: DecodedRailPlaceId): void {
  if (value.provider !== "transitous" || !journeyPlanningCountryCodes.has(value.countryCode)
    || (value.kind === "station"
      && !isEligibleStation(value.nativeId, value.countryCode))) {
    throw new Error("Rail place is not eligible for journey planning");
  }
}

function cursor(value: string | null | undefined): string | null {
  return value === undefined || value === null || value.length === 0 ? null : value;
}

export class TransitousJourneyProvider implements JourneySearchProvider {
  constructor(
    private readonly baseUrl = transitousAPIOrigin,
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
  ) {}

  async searchPlaces(query: string, limit: number): Promise<RailPlaceSnapshot[]> {
    const alias = transitousSearchAlias(query);
    const searchValue = alias.searchValue;
    const resultLimit = Number.isFinite(limit) ? Math.max(0, Math.floor(limit)) : 0;
    if (searchValue.length < 2 || resultLimit === 0) return [];
    const url = new URL("/api/v1/geocode", this.baseUrl);
    url.search = new URLSearchParams({
      text: searchValue,
      mode: mainlineRailModesParameter,
      language: "en",
      numResults: "50",
    }).toString();
    const payload = await this.requestJson(url);
    if (!Array.isArray(payload)) {
      throw new JourneyProviderUnavailableError("Transitous returned an invalid response");
    }
    const geocodes = payload.filter(isGeocodeResult);
    const stops = geocodes.filter(isAcceptedStop);
    const candidates: PlaceCandidate[] = [];

    for (const [index, value] of geocodes.entries()) {
      if (isAcceptedStop(value)) {
        candidates.push({
          place: placeSnapshot(value, "station", acceptedModes(value)),
          providerName: value.name,
          sourceIndex: index,
          source: value,
        });
        continue;
      }
      const country = countryCode(value);
      if (value.type !== "PLACE" || normalizedText(value.name) === null || normalizedText(value.id) === null
        || !isMunicipality(value)
        || country === null || !journeyPlanningCountryCodes.has(country)
        || !validCoordinate(value.lat, value.lon)) continue;
      const nearbyStops = stops.filter((stop) =>
        countryCode(stop) === country && distanceInMeters(value, stop) <= cityStationRadiusMeters);
      if (nearbyStops.length === 0) continue;
      candidates.push({
        place: placeSnapshot(value, "city", [...new Set(nearbyStops.flatMap(acceptedModes))]),
        providerName: value.name,
        sourceIndex: index,
        source: value,
      });
    }

    const comparableQuery = comparable(searchValue);
    const ordered = relevantCandidates(candidates, comparableQuery)
      .sort((left, right) => rank(left, comparableQuery, alias.preferredNativeId)
        - rank(right, comparableQuery, alias.preferredNativeId)
      || left.sourceIndex - right.sourceIndex);
    const deduplicated: PlaceCandidate[] = [];
    for (const candidate of ordered) {
      if (!deduplicated.some((existing) => existing.place.id === candidate.place.id)
        && !isCanonicalCityDuplicate(candidate, deduplicated)) deduplicated.push(candidate);
    }
    return deduplicated
      .slice(0, resultLimit)
      .map((candidate) => candidate.place);
  }

  async searchJourneys(input: ProviderJourneySearchRequest): Promise<ProviderJourneySearchResult> {
    const origin = transitousJourneyEndpointAlias(decodeRailPlaceId(input.originId));
    const destination = transitousJourneyEndpointAlias(decodeRailPlaceId(input.destinationId));
    assertEligibleEndpoint(origin);
    assertEligibleEndpoint(destination);
    const url = new URL("/api/v6/plan", this.baseUrl);
    const parameters = new URLSearchParams({
      fromPlace: endpoint(origin),
      toPlace: endpoint(destination),
      maxTransfers: String(Math.min(input.maxTransfers, 4)),
      transitModes: mainlineRailModesParameter,
      directModes: "",
      detailedLegs: "false",
      detailedTransfers: "false",
      joinInterlinedLegs: "false",
      language: "en",
    });
    if (input.providerCursor === null) {
      parameters.set("time", input.time);
      parameters.set("arriveBy", String(input.arriveBy));
    } else {
      parameters.set("pageCursor", input.providerCursor);
    }
    if (origin.kind === "city" || destination.kind === "city") {
      parameters.set("radius", String(cityStationRadiusMeters));
    }
    url.search = parameters.toString();
    const payload = await this.requestJson(url);
    if (!validPlanResponse(payload)) {
      throw new JourneyProviderUnavailableError("Transitous returned an invalid response");
    }
    let options;
    try {
      options = normalizeJourneyOptions(payload, {
        originKind: origin.kind,
        destinationKind: destination.kind,
        fetchedAt: this.now().toISOString(),
        attributions,
      });
    } catch {
      throw new JourneyProviderUnavailableError("Transitous returned an invalid response");
    }
    if (!hasValidNormalizedOptions(options)) {
      throw new JourneyProviderUnavailableError("Transitous returned an invalid response");
    }
    return {
      options,
      previousProviderCursor: cursor(payload.previousPageCursor),
      nextProviderCursor: cursor(payload.nextPageCursor),
      attributions: [...attributions],
    };
  }

  private async requestJson(url: URL): Promise<unknown> {
    const signal = AbortSignal.timeout(transitousRequestTimeoutMilliseconds);
    let response: Response;
    try {
      response = await this.fetcher(url, {
        headers: { accept: "application/json", "user-agent": transitousUserAgent },
        signal,
      });
    } catch (error) {
      if (isTransitousTimeout(error, signal)) {
        throw new JourneyProviderUnavailableError("Transitous request timed out");
      }
      throw new JourneyProviderUnavailableError("Transitous request failed");
    }
    if (!response.ok) throw new JourneyProviderUnavailableError(`Transitous returned ${response.status}`);
    try {
      return await response.json() as unknown;
    } catch (error) {
      if (isTransitousTimeout(error, signal)) {
        throw new JourneyProviderUnavailableError("Transitous request timed out");
      }
      throw new JourneyProviderUnavailableError("Transitous returned an invalid response");
    }
  }
}
