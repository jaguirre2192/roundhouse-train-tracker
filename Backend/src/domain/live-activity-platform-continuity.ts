import type { LiveActivityContentState } from "./live-activity.js";

const boardingPhases = new Set<LiveActivityContentState["phase"]>(["upcoming", "departureSoon"]);

/** The initial phone payload may be the only official evidence before the first server poll. */
export function preserveBoardingPlatform(
  previous: LiveActivityContentState,
  next: LiveActivityContentState,
): LiveActivityContentState {
  const knownOfficialSource = previous.platformSource !== undefined && previous.platformSource !== "Transitous";
  const fallback = next.platformSource === undefined || next.platformSource === "Transitous";
  if (!knownOfficialSource || !fallback || previous.platformBasis !== "reported" || previous.platform === null
    || !boardingPhases.has(previous.phase) || !boardingPhases.has(next.phase)
    || previous.focusName !== next.focusName || next.isStopCancelled) return next;
  return { ...next, platform: previous.platform, platformBasis: previous.platformBasis,
    platformChanged: previous.platformChanged, platformSource: previous.platformSource!,
    validUntil: Math.min(previous.validUntil, next.validUntil) };
}
