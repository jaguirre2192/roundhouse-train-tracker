import type { ProviderSource, TripSnapshot } from "./snapshot.js";

const fastPlatformSources = new Set<ProviderSource>(["db", "sncf", "irail", "renfe"]);
const fastPlatformCountries = new Set(["AU", "BE", "CH", "DE", "ES", "FI", "FR", "LI", "MC", "NL", "NO", "PL"]);

export type PollLane = "platform" | "full-trip";

export function hasFastPlatformCountry(snapshot: TripSnapshot): boolean {
  return snapshot.stops.some((stop) => !stop.passed && fastPlatformCountries.has(stop.countryCode));
}

export function pollIntervalSeconds(
  source: ProviderSource,
  lane: PollLane,
  snapshot: TripSnapshot | null,
  now = new Date(),
): number {
  const hasFastCountryOverlay = snapshot !== null && snapshot !== undefined && hasFastPlatformCountry(snapshot);
  if (lane === "platform" && (fastPlatformSources.has(source) || hasFastCountryOverlay)) return 20;
  if (source === "ekispert" || source === "srbijavoz") return 900;
  if (source === "tdx") return 120;
  if (source === "chepe") return 21_600;

  const relevantStop = snapshot?.stops.find((stop) => !stop.passed);
  const departure = relevantStop?.expectedDeparture ?? relevantStop?.scheduledDeparture;
  if (departure === undefined || departure === null) return 120;

  const minutesUntilDeparture = (Date.parse(departure) - now.getTime()) / 60_000;
  if (minutesUntilDeparture <= 30 && minutesUntilDeparture >= -180) return 30;
  if (minutesUntilDeparture <= 180) return 60;
  return 300;
}
