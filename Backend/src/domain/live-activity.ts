import type { CanonicalTripReference } from "./snapshot.js";

export interface LiveActivityContentState {
  schemaVersion: 1;
  phase: "upcoming" | "departureSoon" | "underway" | "ended" | "cancelled" | "unavailable";
  focusName: string;
  eventTime: number | null;
  timeZoneIdentifier: string | null;
  timingBasis: "scheduled" | "estimated" | "unavailable";
  platform: string | null;
  platformBasis: "scheduled" | "reported" | "predicted" | "unavailable";
  platformChanged: boolean;
  delayMinutes: number | null;
  checkedAt: number | null;
  validUntil: number;
  isStopCancelled: boolean;
  /** Optional in schema 1: "track" at Amtrak stations; absent reads as "platform". */
  platformKind?: "track" | "platform";
  /** Optional in schema 1: live feed credited for a shown assignment, e.g. "Amtraker". */
  platformSource?: string;
  boardingPlatformSequence?: number;
}

export interface LiveActivityRegistration {
  schemaVersion: 1;
  installationId: string;
  activityId: string;
  token: string;
  tokenGeneration: number;
  environment: "sandbox" | "production";
  trip: CanonicalTripReference;
  boardingStationId: string;
  alightingStationId: string;
  boardingStopSequence: number;
  alightingStopSequence: number;
  /** Older clients have no explicit watch/ride selection. */
  isRiding?: boolean;
  stationTimeZones: Record<string, string>;
  startedAt: string;
  initialContentState: LiveActivityContentState;
}

export interface LiveActivityRecord extends LiveActivityRegistration {
  status: "active" | "ending" | "ended";
  validated: boolean;
  expiresAt: number;
  content: LiveActivityContentState;
  failures: number;
}

export interface LiveActivityPush {
  activityId: string;
  token: string;
  tokenGeneration: number;
  environment: "sandbox" | "production";
  revision: number;
  timestamp: number;
  event: "update" | "end";
  content: LiveActivityContentState;
  expiresAt: number;
  /** Lights the screen and plays a sound; only for a reported track or platform the rider must act on. */
  alert?: LiveActivityAlert;
}

export interface LiveActivityAlert {
  title: string;
  body: string;
}

type BoardingSelection = Pick<LiveActivityRegistration, "isRiding" | "boardingStopSequence">;

export function hasActionableBoardingPlatform(state: LiveActivityContentState, selection: BoardingSelection, now: number): boolean {
  return selection.isRiding !== false && state.boardingPlatformSequence === selection.boardingStopSequence
    && (state.phase === "upcoming" || state.phase === "departureSoon") && !state.isStopCancelled
    && state.platformBasis === "reported" && state.platform !== null && state.checkedAt !== null && state.checkedAt <= now
    && state.validUntil > now && state.eventTime !== null && state.eventTime > now;
}

/**
 * A reported boarding track or platform that is new or different is the one update worth
 * interrupting for. Timetable values, predictions and later stops stay silent.
 */
export function liveActivityAlert(previous: LiveActivityContentState, next: LiveActivityContentState,
  selection: BoardingSelection, now: number): LiveActivityAlert | null {
  if (!hasActionableBoardingPlatform(next, selection, now)) return null;
  const sameBoarding = previous.focusName === next.focusName && (previous.phase === "upcoming" || previous.phase === "departureSoon")
    && (previous.boardingPlatformSequence === undefined || previous.boardingPlatformSequence === selection.boardingStopSequence);
  const previousAssignment = sameBoarding && (previous.platformBasis === "reported" || previous.platformBasis === "scheduled")
    ? previous.platform : null;
  if (previous.platformBasis === "reported" && previousAssignment === next.platform) return null;
  const noun = next.platformKind === "track" ? "Track" : "Platform";
  const old = previousAssignment === next.platform ? null : previousAssignment;
  return old === null
    ? { title: `${noun} ${next.platform}`, body: `Board at ${noun.toLowerCase()} ${next.platform} at ${next.focusName}.` }
    : { title: `${noun} changed to ${next.platform}`, body: `Now boarding at ${noun.toLowerCase()} ${next.platform} at ${next.focusName}, not ${old}.` };
}

export interface LiveActivitySender {
  send(message: LiveActivityPush): Promise<void>;
}

export const liveActivityMaximumLifetime = 8 * 60 * 60_000;
export const liveActivityEndDeliveryLifetime = 15 * 60_000;
