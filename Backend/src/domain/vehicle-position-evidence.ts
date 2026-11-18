import type { VehiclePositionSnapshot } from "./snapshot.js";

/** The age limit is explicit: recovery grace is not the same as live-display freshness. */
export function latestRealPosition(
  positions: VehiclePositionSnapshot[] | undefined,
  now: number,
  maximumAge = 300_000,
): VehiclePositionSnapshot | null {
  if (!Number.isFinite(now) || !Number.isFinite(maximumAge) || maximumAge < 0) return null;
  const valid = (positions ?? []).filter((position) => {
    const age = now - Date.parse(position.asOf);
    return position.source === "real" && Number.isFinite(position.confidence) && position.confidence > 0
      && Number.isFinite(position.latitude) && Math.abs(position.latitude) <= 90
      && Number.isFinite(position.longitude) && Math.abs(position.longitude) <= 180
      && (position.latitude !== 0 || position.longitude !== 0)
      && Number.isFinite(age) && age >= -120_000 && age <= maximumAge;
  });
  return valid.sort((left, right) => Date.parse(right.asOf) - Date.parse(left.asOf))[0] ?? null;
}
