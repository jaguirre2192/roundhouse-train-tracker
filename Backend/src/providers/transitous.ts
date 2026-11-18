import { createHash } from "node:crypto";
import type { BoardEntrySnapshot, BoardReference, StationSnapshot } from "../domain/discovery.js";
import type {
  CanonicalTripReference,
  RouteGeometrySnapshot,
  StopSnapshot,
  TripSnapshot,
} from "../domain/snapshot.js";
import { RailProviderNotFoundError, type RailProvider } from "./provider.js";
import { transitousAPIOrigin, transitousUserAgent } from "./transitous-client.js";
import { transitousPlaceCountryCode } from "./transitous-country.js";
import { internationalSearchQueries } from "./japan-search-aliases.js";
import { isMainlineRailMode, mainlineRailModesParameter } from "./mainline-modes.js";
import {
  isTrackableTransitousDeparture,
  isTrackableTransitousStation,
} from "./transitous-mainline-scope.js";
import { searchTranswaStations } from "./transwa-stations.js";
import { publishedAmtrakName } from "./transitous-amtrak-name.js";
import { transitousServiceDate } from "./transitous-service-date.js";
import { transitousRailwayStationAlias } from "./transitous-search-aliases.js";
import { transitousRequestTimeoutMilliseconds } from "./transitous-timeout.js";

interface TransitousAlert {
  code?: string | null;
  headerText: string;
  descriptionText: string;
}

interface TransitousPlace {
  name: string;
  stopId?: string | null;
  country?: string | null;
  lat: number;
  lon: number;
  tz?: string | null;
  arrival?: string | null;
  departure?: string | null;
  scheduledArrival?: string | null;
  scheduledDeparture?: string | null;
  scheduledTrack?: string | null;
  track?: string | null;
  cancelled?: boolean | null;
  alerts?: TransitousAlert[] | null;
}

interface TransitousLeg {
  mode: string;
  from: TransitousPlace;
  to: TransitousPlace;
  headsign?: string | null;
  agencyName?: string | null;
  tripId?: string | null;
  routeShortName?: string | null;
  routeLongName?: string | null;
  tripShortName?: string | null;
  displayName?: string | null;
  intermediateStops?: TransitousPlace[] | null;
  legGeometry?: {
    points: string;
    precision: number;
    length: number;
  } | null;
}

interface TransitousItinerary {
  legs: TransitousLeg[];
}

interface TransitousGeocode {
  type: string;
  name: string;
  id: string;
  lat: number;
  lon: number;
  country?: string | null;
}

interface TransitousStopTime {
  place: TransitousPlace;
  mode: string;
  headsign?: string | null;
  tripTo?: TransitousPlace | null;
  tripId: string;
  routeShortName?: string | null;
  tripShortName?: string | null;
  displayName?: string | null;
  routeLongName?: string | null;
}

interface TransitousStopTimes {
  stopTimes: TransitousStopTime[];
}

function normalized(value: string | null | undefined): string | null {
  const result = value?.trim();
  return result === undefined || result.length === 0 ? null : result;
}

const stationZones = new Set<string>(Intl.supportedValuesOf("timeZone"));

function reportedStationZone(value: string | null | undefined): string | undefined {
  const zone = normalized(value);
  if (!zone || zone.length > 80 || zone.startsWith("Etc/") || !/^[A-Za-z_]+(?:\/[A-Za-z0-9_+-]+)+$/u.test(zone)) return;
  if (stationZones.has(zone)) return zone;
  // A supplier may use an older IANA alias that is absent from supportedValuesOf.
  try { return new Intl.DateTimeFormat("en", { timeZone: zone }).resolvedOptions().timeZone; }
  catch { return; }
}

function append(place: TransitousPlace, places: TransitousPlace[]): void {
  const previous = places.at(-1);
  if (
    previous?.stopId === place.stopId &&
    previous?.scheduledArrival === place.scheduledArrival &&
    previous?.scheduledDeparture === place.scheduledDeparture
  ) return;
  places.push(place);
}

function stop(place: TransitousPlace, index: number, now: Date): StopSnapshot {
  const zone = reportedStationZone(place.tz);
  const nativeId = place.stopId ?? `${place.lat},${place.lon}`;
  return {
    stationId: `eu:transitous:${nativeId}`,
    stationName: place.name,
    ...(zone ? { timeZoneIdentifier: zone } : {}),
    countryCode: transitousPlaceCountryCode(place),
    latitude: place.lat,
    longitude: place.lon,
    sequence: index + 1,
    scheduledArrival: normalized(place.scheduledArrival),
    scheduledDeparture: normalized(place.scheduledDeparture),
    expectedArrival: normalized(place.arrival),
    expectedDeparture: normalized(place.departure),
    plannedPlatform: normalized(place.scheduledTrack),
    expectedPlatform: normalized(place.track),
    platformSource: normalized(place.track) === null ? null : "Transitous",
    platformObservedAt: null,
    cancelled: place.cancelled === true,
    passed: false,
  };
}

function station(value: TransitousGeocode): StationSnapshot {
  const countryCode = transitousPlaceCountryCode({ ...value, stopId: value.id });
  const alias = transitousRailwayStationAlias(value.id, countryCode);
  const nativeId = alias?.nativeId ?? value.id;
  return {
    id: `eu:transitous:${nativeId}`,
    source: "transitous",
    nativeId,
    name: value.name,
    countryCode,
    latitude: alias?.latitude ?? value.lat,
    longitude: alias?.longitude ?? value.lon,
    operatorHints: [],
  };
}

function product(leg: TransitousLeg): string {
  const routeName = [normalized(leg.routeShortName), normalized(leg.tripShortName)]
    .filter(Boolean)
    .join(" ");
  return publishedAmtrakName(leg) ?? normalized(leg.displayName)
    ?? (routeName.length > 0 ? routeName : leg.mode.replaceAll("_", " ").toLowerCase());
}

function alertId(alert: TransitousAlert): string {
  if (normalized(alert.code) !== null) return `transitous-alert-${alert.code}`;
  return `transitous-alert-${createHash("sha256")
    .update(`${alert.headerText}|${alert.descriptionText}`)
    .digest("hex")
    .slice(0, 24)}`;
}

function routeGeometry(legs: TransitousLeg[]): RouteGeometrySnapshot | undefined {
  const segments = legs.flatMap((leg) => {
    const geometry = leg.legGeometry;
    if (geometry === undefined
      || geometry === null
      || typeof geometry.points !== "string"
      || geometry.points.length === 0
      || geometry.points.length > 1_000_000
      || !Number.isInteger(geometry.precision)
      || geometry.precision < 0
      || geometry.precision > 7
      || !Number.isInteger(geometry.length)
      || geometry.length < 2
      || geometry.length > 100_000) return [];
    return [{
      encodedPolyline: geometry.points,
      precision: geometry.precision,
      pointCount: geometry.length,
    }];
  });
  return segments.length === 0 ? undefined : { source: "Transitous/MOTIS", segments };
}

export class TransitousProvider implements RailProvider {
  readonly source = "transitous" as const;
  readonly discoveryScope = "international" as const;

  constructor(
    private readonly baseUrl = transitousAPIOrigin,
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
    private readonly now: () => Date = () => new Date(),
  ) {}

  async searchStations(query: string): Promise<StationSnapshot[]> {
    const value = query.trim();
    if (value.length < 2) return [];
    const payloads = await Promise.all(internationalSearchQueries(value).map(async (searchValue) => {
      const url = new URL("/api/v1/geocode", this.baseUrl);
      url.search = new URLSearchParams({
        text: searchValue,
        type: "STOP",
        mode: mainlineRailModesParameter,
        language: "en",
        numResults: "20",
      }).toString();
      const response = await this.request(url);
      return response.json() as Promise<TransitousGeocode[]>;
    }));
    const unique = new Map<string, StationSnapshot>(
      searchTranswaStations(value).map((result) => [result.id, result]),
    );
    for (const value of payloads.flat()) {
      if (value.type !== "STOP" || !isTrackableTransitousStation(value)) continue;
      const result = station(value);
      if (!unique.has(result.id)) unique.set(result.id, result);
    }
    return [...unique.values()].slice(0, 20);
  }

  async fetchBoard(reference: BoardReference): Promise<BoardEntrySnapshot[]> {
    // Sibling platforms of one station are fetched separately; one failing stop id
    // should thin the board, not blank it.
    const results = await Promise.allSettled(reference.nativeId.split("|").map(async (nativeId) => {
      const url = new URL("/api/v6/stoptimes", this.baseUrl);
      url.search = new URLSearchParams({
        stopId: nativeId,
        time: reference.at,
        arriveBy: String(reference.direction === "arrivals"),
        mode: mainlineRailModesParameter,
        n: "30",
        language: "en",
        withAlerts: "true",
      }).toString();
      const response = await this.request(url);
      return response.json() as Promise<TransitousStopTimes>;
    }));
    const boards = results.flatMap((result) => result.status === "fulfilled" ? [result.value] : []);
    if (boards.length === 0) {
      throw (results.find((result) => result.status === "rejected") as PromiseRejectedResult).reason;
    }
    const arrivals = reference.direction === "arrivals";
    const entries = boards.flatMap((payload) => payload.stopTimes)
      .filter((value) => isMainlineRailMode(value.mode) && isTrackableTransitousDeparture(value))
      .map((value) => ({
      trip: {
        id: `eu:transitous:${value.tripId}`,
        source: this.source,
        nativeId: value.tripId,
        serviceDate: transitousServiceDate(value.tripId, value.place, reference.at),
      },
      stop: stop(value.place, 1, this.now()),
      headsign: normalized(value.headsign) ?? value.tripTo?.name ?? "",
      product: publishedAmtrakName(value) ?? normalized(value.displayName)
        ?? ([normalized(value.routeShortName), normalized(value.tripShortName)].filter(Boolean).join(" ")
          || value.mode.replaceAll("_", " ").toLowerCase()),
      }));
    return [...new Map(entries.map((entry) => [entry.trip.nativeId, entry])).values()]
      .sort((left, right) => {
        const leftTime = (arrivals ? left.stop.expectedArrival : null)
          ?? left.stop.expectedDeparture ?? left.stop.expectedArrival ?? "";
        const rightTime = (arrivals ? right.stop.expectedArrival : null)
          ?? right.stop.expectedDeparture ?? right.stop.expectedArrival ?? "";
        return leftTime.localeCompare(rightTime);
      })
      .slice(0, 30);
  }

  async fetchTrip(reference: CanonicalTripReference): Promise<TripSnapshot> {
    const url = new URL("/api/v6/trip", this.baseUrl);
    url.search = new URLSearchParams({
      tripId: reference.nativeId,
      detailedLegs: "true",
      joinInterlinedLegs: "false",
      language: "en",
    }).toString();
    const response = await this.request(url);

    const itinerary = (await response.json()) as TransitousItinerary;
    const transitLegs = itinerary.legs.filter((leg) => normalized(leg.tripId) !== null);
    const exactJapaneseLegs = reference.nativeId.includes("_jp-")
      ? transitLegs.filter((leg) => leg.tripId === reference.nativeId)
      : [];
    const legs = exactJapaneseLegs.length > 0 ? exactJapaneseLegs : transitLegs;
    const firstLeg = legs[0];
    if (firstLeg === undefined) throw new RailProviderNotFoundError();

    const places: TransitousPlace[] = [];
    for (const leg of legs) {
      append(leg.from, places);
      for (const intermediate of leg.intermediateStops ?? []) append(intermediate, places);
      append(leg.to, places);
    }
    const alerts = places.flatMap((place) => place.alerts ?? []);
    const geometry = routeGeometry(legs);

    return {
      ...reference,
      operatorName: normalized(firstLeg.agencyName) ?? "European rail",
      product: product(firstLeg),
      headsign: normalized(firstLeg.headsign) ?? places.at(-1)?.name ?? "",
      fetchedAt: this.now().toISOString(),
      stops: places.map((place, index) => stop(place, index, this.now())),
      ...(geometry === undefined ? {} : { routeGeometry: geometry }),
      alertIds: [...new Set(alerts.map(alertId))],
    };
  }

  private async request(url: URL): Promise<Response> {
    const response = await this.fetcher(url, {
      headers: {
        accept: "application/json",
        "user-agent": transitousUserAgent,
      },
      signal: AbortSignal.timeout(transitousRequestTimeoutMilliseconds),
    });
    if (!response.ok) throw new Error(`Transitous returned ${response.status}`);
    return response;
  }
}
