import type { VehiclePositionSnapshot } from "../domain/snapshot.js";
import type { DigitrafficTrain } from "./digitraffic-matching.js";

export interface DigitrafficLocation {
  trainNumber: number;
  departureDate: string;
  timestamp: string;
  isGpsLocation?: boolean;
  location?: { type?: string; coordinates?: number[] };
}

export function digitrafficPosition(
  train: Pick<DigitrafficTrain, "trainNumber" | "departureDate">,
  locations: DigitrafficLocation[],
  now: Date,
  source: string,
): VehiclePositionSnapshot[] {
  const matches = locations.filter((location) => location.trainNumber === train.trainNumber
    && location.departureDate === train.departureDate);
  if (matches.length !== 1) return [];
  const location = matches[0]!;
  if (location.isGpsLocation !== true || location.location?.type !== "Point") return [];
  const [longitude, latitude] = location.location.coordinates ?? [];
  const timestamp = Date.parse(location.timestamp);
  const age = now.getTime() - timestamp;
  if (typeof longitude !== "number" || typeof latitude !== "number"
    || !Number.isFinite(longitude) || !Number.isFinite(latitude)
    || Math.abs(latitude) > 90 || Math.abs(longitude) > 180 || (latitude === 0 && longitude === 0)
    || !Number.isFinite(timestamp) || age > 5 * 60_000 || age < -2 * 60_000) return [];
  return [{
    latitude, longitude, heading: null, source: "real", confidence: age < 90_000 ? 1 : 0.8,
    asOf: new Date(timestamp).toISOString(), provider: source,
  }];
}
