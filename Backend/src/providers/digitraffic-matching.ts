import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import type { PlatformObservation } from "./platform-overlay.js";

export interface DigitrafficStation {
  passengerTraffic: boolean;
  stationName: string;
  stationShortCode: string;
  latitude?: number | null;
  longitude?: number | null;
}

export interface DigitrafficRow {
  stationShortCode: string;
  type: "ARRIVAL" | "DEPARTURE";
  scheduledTime: string;
  liveEstimateTime?: string | null;
  actualTime?: string | null;
  commercialTrack?: string | null;
  cancelled: boolean;
}

export interface DigitrafficTrain {
  trainNumber: number;
  departureDate: string;
  commuterLineID?: string | null;
  timeTableRows: DigitrafficRow[];
}

function normalized(value: string): string {
  return value.normalize("NFKD").replace(/\p{Diacritic}/gu, "")
    .replace(/\b(asema|station|railway|rautatieasema)\b/giu, " ")
    .replace(/[^\p{Letter}\p{Number}]+/gu, " ").trim().toLowerCase();
}

export function digitrafficStation(stop: StopSnapshot, stations: DigitrafficStation[]): DigitrafficStation | undefined {
  const key = normalized(stop.stationName);
  const named = stations.filter((station) => normalized(station.stationName) === key);
  if (named.length === 1) return named[0];
  if (stop.latitude === null || stop.longitude === null) return undefined;
  const candidates = stations.map((station) => ({
    station,
    distance: station.latitude == null || station.longitude == null
      ? Number.POSITIVE_INFINITY
      : Math.hypot(station.latitude - stop.latitude!, station.longitude - stop.longitude!),
  })).filter((value) => value.distance < 0.03).sort((left, right) => left.distance - right.distance);
  if (candidates[1]?.distance === candidates[0]?.distance) return undefined;
  return candidates[0]?.station;
}

function eventRows(stop: StopSnapshot, stationCode: string, train: DigitrafficTrain): DigitrafficRow[] {
  return train.timeTableRows.filter((row) => {
    const scheduled = row.type === "ARRIVAL" ? stop.scheduledArrival : stop.scheduledDeparture;
    return row.stationShortCode === stationCode && scheduled !== null
      && Math.abs(Date.parse(row.scheduledTime) - Date.parse(scheduled)) <= 90_000;
  });
}

export function digitrafficTrain(
  stop: StopSnapshot, snapshot: TripSnapshot, stationCode: string, trains: DigitrafficTrain[],
): DigitrafficTrain | undefined {
  const tokens = new Set(snapshot.product.toUpperCase().split(/[^A-Z0-9]+/u).filter(Boolean));
  const explicitNumbers = [...tokens].filter((value) => /^\d+$/u.test(value));
  const candidates = trains.filter((train) => {
    if (train.departureDate !== snapshot.serviceDate) return false;
    const identity = explicitNumbers.length > 0
      ? explicitNumbers.includes(String(train.trainNumber))
      : train.commuterLineID != null && tokens.has(train.commuterLineID.toUpperCase());
    return identity && eventRows(stop, stationCode, train).length > 0;
  });
  // A commuter line can contain many runs. Station time and operating date must
  // identify exactly one run before using its times or a vehicle position.
  return candidates.length === 1 ? candidates[0] : undefined;
}

function iso(value: string | null | undefined): string | undefined {
  if (value == null || !Number.isFinite(Date.parse(value))) return undefined;
  return new Date(value).toISOString();
}

export function digitrafficObservation(
  stop: StopSnapshot, stationCode: string, train: DigitrafficTrain, observedAt: string, source: string,
): PlatformObservation | null {
  const rows = eventRows(stop, stationCode, train);
  const arrivals = rows.filter((row) => row.type === "ARRIVAL");
  const departures = rows.filter((row) => row.type === "DEPARTURE");
  const arrival = arrivals.length === 1 ? arrivals[0] : undefined;
  const departure = departures.length === 1 ? departures[0] : undefined;
  if (arrival === undefined && departure === undefined) return null;
  const actualArrival = iso(arrival?.actualTime);
  const actualDeparture = iso(departure?.actualTime);
  const expectedArrival = actualArrival ?? iso(arrival?.liveEstimateTime);
  const expectedDeparture = actualDeparture ?? iso(departure?.liveEstimateTime);
  const expectedPlatform = (departure?.commercialTrack ?? arrival?.commercialTrack)?.trim() || null;
  const cancelled = arrival?.cancelled === true || departure?.cancelled === true;
  const reported = (value: string | undefined): value is string => value !== undefined && Date.parse(value) <= Date.parse(observedAt);
  return {
    stopSequence: stop.sequence,
    stationId: stop.stationId,
    plannedPlatform: stop.plannedPlatform,
    expectedPlatform,
    expectedArrival,
    expectedDeparture,
    cancelled,
    ...(reported(actualArrival) ? { arrivalObservedAt: actualArrival } : {}),
    ...(reported(actualDeparture) ? { passed: true, passageObservedAt: actualDeparture } : {}),
    observedAt,
    source,
  };
}
