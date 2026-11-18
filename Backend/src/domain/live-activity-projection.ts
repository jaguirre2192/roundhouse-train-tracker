import { hasReportedArrival, hasReportedPassage } from "./stop-passage.js";
import { latestRealPosition } from "./vehicle-position-evidence.js";
import { routePositionEvidence } from "./route-position-evidence.js";
import type { LiveActivityContentState } from "./live-activity.js";
import { isAmtrakOperated, type StopSnapshot, type TripSnapshot } from "./snapshot.js";

export interface LiveActivityProjectionInput {
  trip: TripSnapshot;
  referenceDate: number;
  lastSuccessfulCheck: number | null;
  refreshFailed: boolean;
  boardingStationId?: string | null;
  alightingStationId?: string | null;
  boardingStopSequence?: number;
  alightingStopSequence?: number;
  stationTimeZones: Record<string, string>;
}

export interface LiveActivityProjection {
  state: LiveActivityContentState;
  eligibility: "available" | "tooEarly" | "ended" | "cancelled" | "unavailable";
  eligibleAt: number | null;
  nextTransitionDate: number | null;
  shouldEnd: boolean;
}

function timestamp(value: string | null): number | null {
  if (value === null) return null;
  const seconds = Date.parse(value) / 1_000;
  return Number.isFinite(seconds) && seconds >= -62_135_596_800 && seconds <= 253_402_300_799 ? seconds : null;
}

function compactText(value: string | null | undefined, maximumBytes: number): string | null {
  let result = "";
  let bytes = 0;
  for (const character of value ?? "") {
    if (/\p{Cc}|\p{Cf}/u.test(character)) continue;
    const size = new TextEncoder().encode(character).length;
    if (bytes + size > maximumBytes) break;
    result += character;
    bytes += size;
  }
  return result.trim() || null;
}

function timing(stop: StopSnapshot | undefined, departure: boolean) {
  if (stop === undefined) return null;
  const candidates = departure
    ? [[stop.expectedDeparture, stop.scheduledDeparture, true], [stop.scheduledDeparture, null, false],
      [stop.expectedArrival, stop.scheduledArrival, true], [stop.scheduledArrival, null, false]] as const
    : [[stop.expectedArrival, stop.scheduledArrival, true], [stop.scheduledArrival, null, false],
      [stop.expectedDeparture, stop.scheduledDeparture, true], [stop.scheduledDeparture, null, false]] as const;
  const candidate = candidates.find(([value]) => value !== null);
  if (candidate === undefined) return null;
  const time = timestamp(candidate[0]);
  if (time === null) return null;
  const scheduled = timestamp(candidate[1]);
  return { time, basis: candidate[2] ? "estimated" as const : "scheduled" as const,
    delay: scheduled === null ? null : Math.trunc((time - scheduled) / 60) };
}

function selectedStops(input: LiveActivityProjectionInput): StopSnapshot[] {
  const stops = input.trip.stops;
  const index = (station: string | null | undefined, sequence: number | undefined, fallback: number) => {
    if (station == null) return fallback;
    const matches = stops.map((stop, i) => ({ stop, i })).filter(({ stop }) =>
      stop.stationId === station && (sequence === undefined || stop.sequence === sequence));
    return matches.length === 1 ? matches[0]!.i : -1;
  };
  const from = index(input.boardingStationId, input.boardingStopSequence, 0);
  const to = index(input.alightingStationId, input.alightingStopSequence, stops.length - 1);
  return from >= 0 && to > from ? stops.slice(from, to + 1) : [];
}

function platform(stop: StopSnapshot | undefined, now: number) {
  const planned = stop?.plannedPlatform?.trim() || null;
  const current = stop?.expectedPlatform?.trim() || null;
  if (current !== null) return { value: current, basis: "reported" as const,
    changed: planned !== null && current !== planned, expiresAt: null };
  if (planned !== null) return { value: planned, basis: "scheduled" as const, changed: false, expiresAt: null };
  const forecast = stop?.platformForecast;
  const expiry = forecast === undefined ? null : timestamp(forecast.expiresAt);
  const generated = forecast === undefined ? null : timestamp(forecast.generatedAt);
  if (forecast?.state === "likely-platform" && forecast.likelyPlatform?.trim()
    && expiry !== null && expiry > now && generated !== null && generated <= now) {
    return { value: forecast.likelyPlatform.trim(), basis: "predicted" as const, changed: false, expiresAt: expiry };
  }
  return { value: null, basis: "unavailable" as const, changed: false, expiresAt: null };
}

function observedArrival(stop: StopSnapshot | undefined, now: number): number | null {
  if (stop === undefined || !hasReportedArrival(stop, new Date(now * 1_000).toISOString())) return null;
  const evidence = [stop.arrivalObservedAt, stop.passed ? stop.passageObservedAt : null]
    .flatMap((value) => {
      const observed = timestamp(value ?? null);
      return observed !== null && observed <= now + 120 ? [observed] : [];
    });
  return evidence.length > 0 ? Math.max(...evidence) : null;
}

/** Timetable context cannot confirm arrival. Only explicit observations may end a journey. */
export function projectLiveActivity(input: LiveActivityProjectionInput): LiveActivityProjection {
  const now = input.referenceDate;
  const checkedAt = input.lastSuccessfulCheck !== null && Number.isFinite(input.lastSuccessfulCheck)
    && input.lastSuccessfulCheck >= -62_135_596_800 && input.lastSuccessfulCheck <= now ? input.lastSuccessfulCheck : null;
  const stops = selectedStops(input);
  const first = stops[0];
  const last = stops.at(-1);
  const departure = timing(first, true)?.time ?? null;
  const arrival = timing(last, false)?.time ?? null;
  const allCancelled = stops.length > 0 && stops.every((stop) => stop.cancelled);
  const cancelledStop = first?.cancelled ? first : last?.cancelled ? last : undefined;
  const selectedCancellation = stops.length >= 2 && cancelledStop !== undefined;
  const transitions: number[] = [];
  let phase: LiveActivityContentState["phase"] = "unavailable";
  let eligibility: LiveActivityProjection["eligibility"] = "unavailable";
  let eligibleAt: number | null = null;
  let shouldEnd = false;
  let unconfirmedElapsedArrival = false;
  let focus: StopSnapshot | undefined;
  let usesDeparture = false;

  if (selectedCancellation) {
    phase = "cancelled";
    eligibility = "cancelled";
    shouldEnd = true;
    focus = cancelledStop;
    usesDeparture = focus === first;
  } else if (stops.length >= 2 && !allCancelled && departure !== null && arrival !== null
    && arrival >= departure && Number.isFinite(now) && now >= -62_135_596_800 && now <= 253_402_300_799) {
    const position = latestRealPosition(input.trip.positions, now * 1_000);
    const route = position === null ? null : routePositionEvidence(input.trip, stops, position);
    const observedAt = observedArrival(last, now);
    const arrivalConfirmed = route?.arrived === true || (observedAt !== null
      && (route === null || !route.isClearlyBeforeDestination || observedAt * 1_000 >= Date.parse(position!.asOf)));
    const recentStopIndex = stops.findLastIndex((stop) => !stop.cancelled
      && (observedArrival(stop, now) ?? -Infinity) >= now - 300);
    const recentStop = recentStopIndex < 0 ? undefined : stops[recentStopIndex]!;
    const reportedFocus = recentStop === undefined ? undefined
      : hasReportedPassage(recentStop, new Date(now * 1_000).toISOString())
        ? stops.slice(recentStopIndex + 1).find((stop) => !stop.cancelled) : recentStop;
    const observedFocus = route === null ? reportedFocus : route.focus ?? undefined;
    if (now < departure) {
      phase = now < departure - 1_800 ? "upcoming" : "departureSoon";
      focus = first;
      usesDeparture = true;
      transitions.push(now < departure - 1_800 ? departure - 1_800 : departure);
    } else if (arrivalConfirmed) {
      phase = "ended";
      focus = last;
      eligibility = "ended";
      // A new report of an existing arrival is not a new arrival event.
      const recoveryEnd = arrival + 1_800;
      transitions.push(recoveryEnd);
      shouldEnd = !input.refreshFailed && checkedAt !== null && now < checkedAt + 300 && now >= recoveryEnd;
    } else if (observedFocus !== undefined) {
      phase = "underway";
      focus = observedFocus;
      if (position !== null) transitions.push(Date.parse(position.asOf) / 1_000 + 300);
    } else if (now >= arrival) {
      // A still-reporting train can run past its timetable. Missing observations
      // mean unknown, never arrived; the activity's technical lifetime is separate.
      unconfirmedElapsedArrival = position === null;
      phase = unconfirmedElapsedArrival ? "unavailable" : "underway";
      eligibility = unconfirmedElapsedArrival ? "unavailable" : "available";
      focus = unconfirmedElapsedArrival ? undefined : last;
      if (position !== null) transitions.push(Date.parse(position.asOf) / 1_000 + 300);
    } else {
      phase = "underway";
      focus = stops.slice(1).find((stop) => !stop.cancelled
        && (timing(stop, stop !== last)?.time ?? -Infinity) > now);
      transitions.push(Math.min(timing(focus, focus !== last)?.time ?? arrival, arrival));
    }
    if (phase !== "ended" && phase !== "unavailable") {
      eligibility = now < departure - 3_600 ? "tooEarly" : "available";
      eligibleAt = eligibility === "tooEarly" ? departure - 3_600 : null;
      transitions.push(departure - 3_600);
    }
  }
  const event = timing(focus, usesDeparture);
  const guidance = platform(focus, now);
  if (guidance.expiresAt !== null) transitions.push(guidance.expiresAt);
  const next = transitions.filter((value) => value > now).sort((a, b) => a - b)[0] ?? null;
  let validUntil = Math.min(checkedAt === null ? now : checkedAt + 300, next ?? Infinity);
  const platformObservedAt = timestamp(focus?.platformObservedAt ?? input.trip.fetchedAt);
  if (guidance.basis === "reported" && platformObservedAt !== null) {
    validUntil = Math.min(validUntil, platformObservedAt <= now ? platformObservedAt + 300 : now);
  }
  if (input.refreshFailed || checkedAt === null || unconfirmedElapsedArrival) validUntil = Math.min(validUntil, now);
  let zone = compactText(focus === undefined ? null : input.stationTimeZones[focus.stationId], 64);
  if (zone !== null) {
    try { new Intl.DateTimeFormat("en", { timeZone: zone }); } catch { zone = null; }
  }
  return {
    state: {
      schemaVersion: 1, phase, focusName: compactText(focus?.stationName ?? "Journey details unavailable", 160) ?? "Journey",
      eventTime: event?.time ?? null, timeZoneIdentifier: zone, timingBasis: event?.basis ?? "unavailable",
      platform: compactText(guidance.value, 32), platformBasis: compactText(guidance.value, 32) === null ? "unavailable" : guidance.basis,
      platformChanged: compactText(guidance.value, 32) !== null && guidance.changed,
      delayMinutes: event?.delay ?? null, checkedAt, validUntil, isStopCancelled: selectedCancellation && !allCancelled,
      ...(isAmtrakOperated(input.trip) ? { platformKind: "track" as const } : {}),
      ...((phase === "upcoming" || phase === "departureSoon") && first !== undefined && focus === first && guidance.basis === "reported"
        && (first.expectedDeparture ?? first.scheduledDeparture) != null
        && !stops.some((stop) => !stop.cancelled && hasReportedPassage(stop, new Date(now * 1_000).toISOString()))
        && observedArrival(last, now) === null ? { boardingPlatformSequence: first.sequence } : {}),
      ...((compactText(guidance.value, 32) !== null || focus?.platformObservedAt != null) && focus?.platformSource
        ? { platformSource: compactText(focus.platformSource, 32)! } : {}),
    },
    eligibility, eligibleAt, nextTransitionDate: next, shouldEnd,
  };
}
