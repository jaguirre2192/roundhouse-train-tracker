import type { CanonicalTripReference, ExpectedTimeEvidence, StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import type { TripPositionOverlay } from "./trip-position-overlay.js";
import { hasReportedPassage } from "../domain/stop-passage.js";

export interface PlatformObservation {
  stopSequence: number;
  stationId: string | null;
  plannedPlatform?: string | null | undefined;
  expectedPlatform?: string | null | undefined;
  platformSuppressed?: boolean;
  expectedArrival?: string | null | undefined;
  expectedDeparture?: string | null | undefined;
  cancelled?: boolean;
  passed?: boolean;
  passageObservedAt?: string;
  arrivalObservedAt?: string;
  observedAt: string;
  source: string;
}

export interface PlatformRealtimeOverlay {
  readonly sourceName: string;
  readonly supportedCountryCodes: ReadonlySet<string>;
  platformUpdates(snapshot: TripSnapshot): Promise<PlatformObservation[]>;
  tripAlertIds?(snapshot: TripSnapshot): Promise<string[]>;
  /** Warm only an eligible source while its base trip is being resolved. */
  prefetch?(reference: CanonicalTripReference): Promise<void>;
}

function newest(values: PlatformObservation[]): PlatformObservation | undefined {
  return values.reduce<PlatformObservation | undefined>((current, candidate) => {
    if (current === undefined) return candidate;
    return Date.parse(candidate.observedAt) > Date.parse(current.observedAt) ? candidate : current;
  }, undefined);
}

function latest(
  observations: PlatformObservation[],
  predicate: (observation: PlatformObservation) => boolean,
): PlatformObservation | undefined {
  return newest(observations.filter(predicate));
}

function timingEvidence(value: ExpectedTimeEvidence | undefined): ExpectedTimeEvidence | undefined {
  if (value === undefined || !value.source.trim()) return undefined;
  const observed = Date.parse(value.observedAt);
  if (!Number.isFinite(observed) || observed > Date.now()) return undefined;
  return { source: value.source, observedAt: value.observedAt };
}

function latestTiming(observations: PlatformObservation[], field: "expectedArrival" | "expectedDeparture",
  prior: ExpectedTimeEvidence | undefined): PlatformObservation | undefined {
  const candidate = latest(observations, (value) => value[field] !== undefined && timingEvidence(value) !== undefined);
  const previous = timingEvidence(prior);
  return candidate !== undefined && previous !== undefined
    && Date.parse(candidate.observedAt) < Date.parse(previous.observedAt) ? undefined : candidate;
}

function updatedStop(
  stop: StopSnapshot,
  observations: PlatformObservation[],
  snapshotFetchedAt: string,
): StopSnapshot {
  if (observations.length === 0) return stop;
  const planned = latest(observations, (value) => value.plannedPlatform !== undefined);
  const platform = latest(observations, (value) =>
    value.platformSuppressed === true
    || (value.expectedPlatform !== undefined
      && value.expectedPlatform !== null
      && value.expectedPlatform.length > 0)
  );
  const arrival = latestTiming(observations, "expectedArrival", stop.expectedArrivalEvidence);
  const departure = latestTiming(observations, "expectedDeparture", stop.expectedDepartureEvidence);
  const cancellation = latest(observations, (value) => value.cancelled !== undefined);
  const expectedArrival = arrival?.expectedArrival === undefined
    ? stop.expectedArrival
    : arrival.expectedArrival;
  const expectedDeparture = departure?.expectedDeparture === undefined
    ? stop.expectedDeparture
    : departure.expectedDeparture;
  // Operators suppress platforms on purpose (often crowd control at large termini), so a
  // suppression is a realtime observation that hides every platform, including the base
  // provider's timetable guess. Change detection treats the missing value as unknown.
  const suppressed = platform?.platformSuppressed === true;
  const validEvidence = (value: string | undefined): value is string => value !== undefined
    && Number.isFinite(Date.parse(value)) && Date.parse(value) <= Date.parse(snapshotFetchedAt) + 120_000;
  const explicit = observations.filter((value) => value.stationId === stop.stationId
    && validEvidence(value.observedAt));
  const latestProof = (values: (string | undefined)[]) => values.filter(validEvidence)
    .sort((a, b) => Date.parse(b) - Date.parse(a))[0];
  const passageObservedAt = latestProof([
    ...(hasReportedPassage(stop, snapshotFetchedAt) ? [stop.passageObservedAt] : []),
    ...explicit.filter((value) => value.passed === true).map((value) => value.passageObservedAt),
  ]);
  const arrivalObservedAt = latestProof([stop.arrivalObservedAt, ...explicit.map((value) => value.arrivalObservedAt)]);
  // Keep untouched provenance literal. Dropping a known invalid old clock could
  // incorrectly turn its forecast into an unqualified base-provider estimate.
  const { expectedArrivalEvidence: priorArrivalEvidence, expectedDepartureEvidence: priorDepartureEvidence, ...base } = stop;
  const expectedArrivalEvidence = expectedArrival === null ? undefined
    : arrival === undefined ? priorArrivalEvidence : timingEvidence(arrival);
  const expectedDepartureEvidence = expectedDeparture === null ? undefined
    : departure === undefined ? priorDepartureEvidence : timingEvidence(departure);
  return {
    ...base,
    plannedPlatform: suppressed ? null : planned?.plannedPlatform ?? stop.plannedPlatform,
    expectedPlatform: suppressed ? null : platform?.expectedPlatform ?? stop.expectedPlatform,
    expectedArrival,
    expectedDeparture,
    ...(expectedArrivalEvidence === undefined ? {} : { expectedArrivalEvidence }),
    ...(expectedDepartureEvidence === undefined ? {} : { expectedDepartureEvidence }),
    cancelled: cancellation?.cancelled ?? stop.cancelled,
    platformSource: platform?.source ?? stop.platformSource,
    platformObservedAt: platform?.observedAt ?? stop.platformObservedAt,
    passed: passageObservedAt !== undefined
      && (arrivalObservedAt === undefined || Date.parse(passageObservedAt) >= Date.parse(arrivalObservedAt)),
    ...(passageObservedAt === undefined ? {} : { passageObservedAt }),
    ...(arrivalObservedAt === undefined ? {} : { arrivalObservedAt }),
  };
}

const defaultOverlayDeadlineMilliseconds = 3_000;

class OverlayDeadlineError extends Error {
  constructor(milliseconds: number) {
    super(`overlay missed its ${milliseconds} ms deadline`);
  }
}

// Races an overlay call against its share of the cycle budget. The underlying request
// keeps running, so a slow feed still warms its cache for the next cycle.
async function beforeDeadline<T>(work: () => Promise<T>, deadlineAt: number, budget: number): Promise<T> {
  const remaining = Math.max(0, deadlineAt - Date.now());
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      work(),
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new OverlayDeadlineError(budget)), remaining);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

export class TripSnapshotEnricher {
  constructor(
    private readonly overlays: PlatformRealtimeOverlay[],
    private readonly positionOverlays: TripPositionOverlay[] = [],
    private readonly overlayDeadlineMilliseconds = defaultOverlayDeadlineMilliseconds,
  ) {}

  async prefetch(reference: CanonicalTripReference): Promise<void> {
    // Each source owns eligibility, coalescing, expiry and failure cooldowns.
    // An unavailable optional source never rejects the base trip lookup.
    const sources = [...new Set([...this.overlays, ...this.positionOverlays])];
    await Promise.allSettled(sources.filter((overlay) => overlay.prefetch !== undefined)
      .map((overlay) => Promise.resolve().then(() => overlay.prefetch!(reference))));
  }

  async enrich(snapshot: TripSnapshot): Promise<TripSnapshot> {
    const countries = new Set(snapshot.stops.map((stop) => stop.countryCode.toUpperCase()));
    const applicable = this.overlays.filter((overlay) =>
      [...overlay.supportedCountryCodes].some((code) => countries.has(code.toUpperCase()))
    );
    const budget = this.overlayDeadlineMilliseconds;
    const results = await Promise.all(applicable.map(async (overlay) => {
      const deadlineAt = Date.now() + budget;
      // These feeds are independent. A stalled timing/platform request must not
      // consume the alert feed's entire budget before it even starts.
      const [observations, alertIds] = await Promise.all([
        beforeDeadline(() => overlay.platformUpdates(snapshot), deadlineAt, budget)
          .catch((error): PlatformObservation[] => {
            console.error("platform overlay failed", { source: overlay.sourceName, error });
            return [];
          }),
        beforeDeadline(async () => await overlay.tripAlertIds?.(snapshot) ?? [], deadlineAt, budget)
          .catch((error): string[] => {
            console.error("alert overlay failed", { source: overlay.sourceName, error });
            return [];
          }),
      ]);
      return { observations, alertIds };
    }));
    const grouped = new Map<number, PlatformObservation[]>();
    for (const observation of results.flatMap((result) => result.observations)) {
      const values = grouped.get(observation.stopSequence) ?? [];
      values.push(observation);
      grouped.set(observation.stopSequence, values);
    }
    const officialAlertIds = results.flatMap((result) => result.alertIds);
    const alertEnriched = officialAlertIds.length === 0 ? snapshot : {
      ...snapshot,
      alertIds: [...new Set([...snapshot.alertIds, ...officialAlertIds])],
    };
    const stopEnriched = grouped.size === 0 ? alertEnriched : {
      ...alertEnriched,
      stops: alertEnriched.stops.map((stop) =>
        updatedStop(stop, grouped.get(stop.sequence) ?? [], alertEnriched.fetchedAt)),
    };
    const positionSources = this.positionOverlays.filter((overlay) =>
      [...overlay.supportedCountryCodes].some((code) => countries.has(code.toUpperCase()))
    );
    const positions = (await Promise.all(positionSources.map(async (overlay) => {
      try {
        return await beforeDeadline(() => overlay.positionUpdates(stopEnriched), Date.now() + budget, budget);
      } catch (error) {
        console.error("position overlay failed", { source: overlay.sourceName, error });
        return [];
      }
    }))).flat();
    if (positions.length === 0) return stopEnriched;
    return { ...stopEnriched, positions };
  }
}
