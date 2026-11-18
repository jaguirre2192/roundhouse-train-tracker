import type { TripSnapshot } from "./snapshot.js";

/** Losing an overlay is not a platform change. Never transfer evidence between stations. */
export function carryForwardPlatforms(previous: TripSnapshot | null, current: TripSnapshot): TripSnapshot {
  if (previous === null) return current;
  const previousStops = new Map(previous.stops.map((stop) => [stop.sequence, stop]));
  return {
    ...current,
    stops: current.stops.map((stop) => {
      const oldStop = previousStops.get(stop.sequence);
      if (oldStop?.stationId !== stop.stationId || stop.passed || stop.platformObservedAt !== null
        || oldStop.platformObservedAt == null || oldStop.expectedPlatform === null) return stop;
      return { ...stop, expectedPlatform: oldStop.expectedPlatform,
        platformSource: oldStop.platformSource, platformObservedAt: oldStop.platformObservedAt };
    }),
  };
}
