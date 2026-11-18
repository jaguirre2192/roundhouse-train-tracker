import type { RenfeCallUpdate, RenfeTripDescriptor } from "./renfe-service-identity.js";

export const renfeLongDistanceVehicleURL = "https://gtfsrt.renfe.com/vehicle_positions_LD.json";
export const renfeLongDistanceUpdatesURL = "https://gtfsrt.renfe.com/trip_updates_LD.json";

export interface RenfeFeed<Entity> {
  header: { timestamp?: string | null };
  entity: Entity[];
  /** Transport metadata is assigned by our fetcher, never taken from the JSON body. */
  transport?: { url: string; receivedAt: number; lastModified: number | null };
}

export interface RenfeVehicle {
  trip: RenfeTripDescriptor;
  timestamp?: string | null;
  stopId?: string | null;
  position?: { latitude?: number | null; longitude?: number | null; bearing?: number | null } | null;
  vehicle?: { id?: string | null; label?: string | null } | null;
}

export interface RenfeVehicleEntity { id?: string | null; vehicle?: RenfeVehicle | null }

export interface RenfeTripUpdate {
  trip: RenfeTripDescriptor;
  timestamp?: string | null;
  delay?: number | string | null;
  stopTimeUpdate?: RenfeCallUpdate[] | null;
}

export interface RenfeTripUpdateEntity { id?: string | null; tripUpdate?: RenfeTripUpdate | null }

export function renfeInstant(value: unknown): Date | null {
  if (value === null || value === undefined || value === "") return null;
  const seconds = Number(value);
  const date = new Date(seconds * 1_000);
  return Number.isFinite(seconds) && !Number.isNaN(date.getTime()) ? date : null;
}
