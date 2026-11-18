import type { CanonicalTripReference, TripSnapshot, VehiclePositionSnapshot } from "../domain/snapshot.js";

export interface TripPositionOverlay {
  readonly sourceName: string;
  readonly supportedCountryCodes: ReadonlySet<string>;
  positionUpdates(snapshot: TripSnapshot): Promise<VehiclePositionSnapshot[]>;
  prefetch?(reference: CanonicalTripReference): Promise<void>;
}
