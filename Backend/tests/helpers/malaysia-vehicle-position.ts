import { transit_realtime } from "gtfs-realtime-bindings";
import type { TripSnapshot } from "../../src/domain/snapshot.js";

export function response(change?: (vehicle: transit_realtime.IVehiclePosition) => void): Response {
  const vehicle: transit_realtime.IVehiclePosition = {
    trip: { tripId: "weekday_2178" },
    vehicle: { id: "weekday_2178", label: "SCS26" },
    position: { latitude: 3.1139569, longitude: 101.6730347, bearing: 185, speed: 80 },
    timestamp: 1_784_638_477,
  };
  change?.(vehicle);
  const value = transit_realtime.FeedMessage.encode({
    header: { gtfsRealtimeVersion: "2.0", timestamp: 1_784_638_477 },
    entity: [{
      id: "9",
      vehicle,
    }],
  }).finish();
  const copy = new Uint8Array(value.byteLength);
  copy.set(value);
  return new Response(copy.buffer, { status: 200 });
}

export function snapshot(): TripSnapshot {
  return {
    id: "eu:transitous:20260721_19:55_my-ktmb_2178",
    source: "transitous",
    nativeId: "20260721_19:55_my-ktmb_2178",
    serviceDate: "2026-07-21",
    operatorName: "KTMB",
    product: "ETS 2178",
    headsign: "KL Sentral",
    fetchedAt: "2026-07-21T12:00:00.000Z",
    alertIds: [],
    stops: [{
      stationId: "eu:transitous:my-ktmb_19100",
      stationName: "KL Sentral",
      countryCode: "MY",
      latitude: 3.134,
      longitude: 101.686,
      sequence: 1,
      scheduledArrival: null,
      scheduledDeparture: "2026-07-21T12:00:00.000Z",
      expectedArrival: null,
      expectedDeparture: "2026-07-21T12:00:00.000Z",
      plannedPlatform: null,
      expectedPlatform: null,
      platformSource: null,
      platformObservedAt: null,
      cancelled: false,
      passed: false,
    }],
  };
}
