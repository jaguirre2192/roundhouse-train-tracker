import { denmarkSiriMaximumAgeMilliseconds, type DenmarkSiriCall, type DenmarkSiriJourney } from "./denmark-siri-models.js";

export function denmarkSiriJourneyKey(journey: Pick<DenmarkSiriJourney, "serviceDate" | "operatorRef" | "journeyRef">): string {
  return `${journey.serviceDate}|${journey.operatorRef}|${journey.journeyRef}`;
}

function callKey(call: DenmarkSiriCall): string {
  return `${call.stopPointRef}|${call.aimedArrival ?? ""}|${call.aimedDeparture ?? ""}`;
}

function content(call: DenmarkSiriCall): string {
  return JSON.stringify([call.expectedArrival ?? null, call.expectedDeparture ?? null]);
}

function fresh(call: DenmarkSiriCall, now: number): boolean {
  const observed = Date.parse(call.observedAt);
  return Number.isFinite(observed) && observed <= now + 120_000 && now - observed <= denmarkSiriMaximumAgeMilliseconds;
}

/** Partial messages update their own calls; reception never renews an old source clock. */
export function mergeDenmarkSiriEvents(
  previous: readonly DenmarkSiriJourney[], incoming: readonly DenmarkSiriJourney[], now: Date,
): DenmarkSiriJourney[] {
  const instant = now.getTime();
  if (!Number.isFinite(instant)) return [];
  const journeys = new Map<string, DenmarkSiriJourney>();
  for (const journey of [...previous, ...incoming]) {
    const calls = journey.calls.filter((call) => fresh(call, instant));
    if (calls.length === 0) continue;
    const key = denmarkSiriJourneyKey(journey);
    const existing = journeys.get(key);
    if (existing !== undefined && existing.trainNumber !== journey.trainNumber) {
      // A dated journey reference cannot change its public train identity.
      continue;
    }
    const merged = new Map((existing?.calls ?? []).map((call) => [callKey(call), { ...call }]));
    for (const call of calls) {
      const id = callKey(call);
      const prior = merged.get(id);
      if (prior === undefined || Date.parse(call.observedAt) > Date.parse(prior.observedAt)) merged.set(id, { ...call });
      else if (call.observedAt === prior.observedAt && (call.conflicted === true || prior.conflicted === true || content(call) !== content(prior))) {
        merged.set(id, { ...prior, conflicted: true });
      }
    }
    const latest = existing === undefined || Date.parse(journey.observedAt) > Date.parse(existing.observedAt) ? journey : existing;
    journeys.set(key, { ...latest, calls: [...merged.values()].sort((left, right) => callKey(left).localeCompare(callKey(right))) });
  }
  // Bound durable state and keep recently source-observed journeys first.
  return [...journeys.values()].sort((left, right) => Date.parse(right.observedAt) - Date.parse(left.observedAt)).slice(0, 512);
}
