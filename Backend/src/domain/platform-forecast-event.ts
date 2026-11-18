import type { HistoricalPlatformForecast, HistoricalPlatformObservation, PlatformEventType, PlatformForecastRequest } from "./platform-forecast.js";
import type { CanonicalPlatformObservation, CanonicalPlatformObservationPayload } from "./platform-observation.js";
import { routeSignature } from "./platform-observation.js";
import type { StopSnapshot, TripSnapshot } from "./snapshot.js";

export function platformEventType(snapshot: TripSnapshot, stop: StopSnapshot): PlatformEventType | null {
  if (stop.sequence === snapshot.stops[0]?.sequence && stop.scheduledDeparture !== null) return "departure";
  if (stop.scheduledArrival !== null) return "arrival";
  if (stop.scheduledDeparture !== null) return "departure";
  return null;
}

export function platformScheduledTime(stop: StopSnapshot, type: PlatformEventType): string | null {
  return type === "departure" ? stop.scheduledDeparture : stop.scheduledArrival;
}

export function platformEventId(
  tripSource: string,
  nativeTripId: string,
  serviceDate: string,
  stationId: string,
  stopSequence: number,
  type: PlatformEventType,
): string {
  return [tripSource, nativeTripId, serviceDate, stationId, stopSequence, type].join("|");
}

export function historicalObservationFromPayload(
  payload: CanonicalPlatformObservationPayload,
  type: PlatformEventType,
): HistoricalPlatformObservation | null {
  const time = type === "departure" ? payload.stop.scheduledDeparture : payload.stop.scheduledArrival;
  if (time === null) return null;
  return {
    eventId: platformEventId(
      payload.trip.source,
      payload.trip.nativeId,
      payload.trip.serviceDate,
      payload.stop.stationId,
      payload.stop.sequence,
      type,
    ),
    stationId: payload.stop.stationId,
    sourceName: payload.provenance.sourceName,
    operatorName: payload.trip.operatorName,
    product: payload.trip.product,
    headsign: payload.trip.headsign,
    routeSignature: payload.trip.routeSignature,
    eventType: type,
    serviceDate: payload.trip.serviceDate,
    scheduledTime: time,
    effectivePlatform: payload.stop.effectivePlatform,
    finalObservedAt: payload.provenance.sourceObservedAt,
  };
}

export function platformForecastRequest(
  snapshot: TripSnapshot,
  stop: StopSnapshot,
  type: PlatformEventType,
  sourceName: string,
  generatedAt: string,
): PlatformForecastRequest | null {
  const time = platformScheduledTime(stop, type);
  if (time === null) return null;
  return {
    eventId: platformEventId(
      snapshot.source,
      snapshot.nativeId,
      snapshot.serviceDate,
      stop.stationId,
      stop.sequence,
      type,
    ),
    stationId: stop.stationId,
    sourceName,
    operatorName: snapshot.operatorName,
    product: snapshot.product,
    headsign: snapshot.headsign,
    routeSignature: routeSignature(snapshot),
    eventType: type,
    serviceDate: snapshot.serviceDate,
    scheduledTime: time,
    generatedAt,
    officialPlatform: stop.expectedPlatform ?? stop.plannedPlatform,
  };
}

export function platformShadowForecastId(
  request: PlatformForecastRequest,
  forecast: HistoricalPlatformForecast,
): string {
  return [request.eventId, forecast.horizon, forecast.modelVersion, forecast.timetablePeriod].join("|");
}

export function observationEventIds(observation: CanonicalPlatformObservation): string[] {
  const types: PlatformEventType[] = [];
  if (observation.scheduledArrival !== null) types.push("arrival");
  if (observation.scheduledDeparture !== null) types.push("departure");
  return types.map((type) => platformEventId(
    observation.tripSource,
    observation.nativeTripId,
    observation.serviceDate,
    observation.stationId,
    observation.stopSequence,
    type,
  ));
}
