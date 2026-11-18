export const mainlineRailModes = [
  "HIGHSPEED_RAIL",
  "LONG_DISTANCE",
  "NIGHT_RAIL",
  "REGIONAL_RAIL",
] as const;

export const mainlineRailModesParameter = mainlineRailModes.join(",");

const mainlineRailModeSet = new Set<string>(mainlineRailModes);

export function isMainlineRailMode(mode: string): boolean {
  return mainlineRailModeSet.has(mode.toUpperCase());
}
