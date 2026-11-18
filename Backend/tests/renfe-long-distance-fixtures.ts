import type { TripSnapshot } from "../src/domain/snapshot.js";
import { renfeLongDistanceUpdatesURL, renfeLongDistanceVehicleURL,
  type RenfeFeed, type RenfeTripUpdateEntity, type RenfeVehicleEntity } from "../src/providers/renfe-realtime-models.js";
import type { VerifiedRenfeUpdate } from "../src/providers/renfe-long-distance-timing.js";

export const start = Date.parse("2026-11-13T18:00:00Z");
export const tripId = "0518112026-11-12";
export function ldSnapshot(): TripSnapshot {
  const times = ["2026-11-13T17:00:00Z", "2026-11-13T18:00:00Z", "2026-11-13T19:00:00Z"];
  return { id: "es-test", source: "transitous", nativeId: `20261113_18:00_es-RENFE-Larga-Distancia-y-AVE_${tripId}`,
    serviceDate: "2026-11-13", operatorName: "RENFE", product: "AVE 05181", headsign: "Madrid",
    fetchedAt: new Date(start).toISOString(), alertIds: [], stops: times.map((time, index) => ({
      stationId: `es-RENFE-Larga-Distancia-y-AVE_${index + 1}`, stationName: `Stop ${index + 1}`, countryCode: "ES",
      latitude: 40, longitude: -4 + index, sequence: index + 1,
      scheduledArrival: index === 0 ? null : time, scheduledDeparture: index === 2 ? null : time,
      expectedArrival: index === 0 ? null : time, expectedDeparture: index === 2 ? null : time,
      plannedPlatform: null, expectedPlatform: null, platformSource: null, platformObservedAt: null,
      passed: false, cancelled: false,
    })) };
}
export function ldUpdate(at = start): VerifiedRenfeUpdate {
  const update = { trip: { tripId, scheduleRelationship: "SCHEDULED" }, delay: 0,
    stopTimeUpdate: [{ stopId: "3", arrival: { delay: 0, time: String((at - 5_580_000) / 1_000) } }] };
  const feed: RenfeFeed<RenfeTripUpdateEntity> = { header: { timestamp: String(at / 1_000) }, entity: [{ tripUpdate: update }],
    transport: { url: renfeLongDistanceUpdatesURL, receivedAt: at, lastModified: at } };
  return { feed, update, delay: 0, cancelled: false, observedAt: new Date(at) };
}
export function ldVehicles(at = start, longitude = -3, offset = 3_600_000): RenfeFeed<RenfeVehicleEntity> {
  return { header: { timestamp: String((at - offset) / 1_000) },
    transport: { url: renfeLongDistanceVehicleURL, receivedAt: at, lastModified: at },
    entity: [{ vehicle: { trip: { tripId }, stopId: "3", position: { latitude: 40, longitude } } }] };
}
