import type { BoardEntrySnapshot, StationSnapshot } from "../domain/discovery.js";
import type {
  PlatformCorpusSamplingPersistence,
  PlatformSampleTarget,
  PlatformSamplingRunReport,
} from "../domain/platform-sampling.js";
import type { StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import { ProviderRegistry } from "../providers/provider.js";

const stationQuery = "Berlin Hbf";
const destination = "München Hbf";
const maximumPollsPerRun = 4;
const minimumLeadMilliseconds = 5 * 60_000;
const maximumLeadMilliseconds = 90 * 60_000;

function normalized(value: string): string {
  return value
    .normalize("NFKD")
    .replace(/\p{Diacritic}/gu, "")
    .replace(/[^\p{Letter}\p{Number}]+/gu, " ")
    .trim()
    .toLocaleLowerCase("de-DE");
}

function approvedDELFIReference(nativeId: string): boolean {
  return /_de-DELFI_/u.test(nativeId);
}

function eventTime(stop: StopSnapshot): number | null {
  const value = stop.expectedDeparture
    ?? stop.expectedArrival
    ?? stop.scheduledDeparture
    ?? stop.scheduledArrival;
  const milliseconds = Date.parse(value ?? "");
  return Number.isFinite(milliseconds) ? milliseconds : null;
}

function departureTime(entry: BoardEntrySnapshot): number | null {
  const value = entry.stop.expectedDeparture
    ?? entry.stop.scheduledDeparture
    ?? entry.stop.expectedArrival
    ?? entry.stop.scheduledArrival;
  const milliseconds = Date.parse(value ?? "");
  return Number.isFinite(milliseconds) ? milliseconds : null;
}

function exactFocusStation(stations: StationSnapshot[]): StationSnapshot | null {
  const expected = normalized(stationQuery);
  return stations.find((station) => station.source === "transitous"
    && station.countryCode === "DE"
    && normalized(station.name) === expected) ?? null;
}

function eligibleEntry(
  entry: BoardEntrySnapshot,
  now: number,
  seen: (id: string) => boolean,
): boolean {
  const departure = departureTime(entry);
  return entry.trip.source === "transitous"
    && approvedDELFIReference(entry.trip.nativeId)
    && !seen(entry.trip.id)
    && /^ICE\b/u.test(entry.product.trim().toUpperCase())
    && normalized(entry.headsign) === normalized(destination)
    && entry.stop.countryCode === "DE"
    && departure !== null
    && departure >= now + minimumLeadMilliseconds
    && departure <= now + maximumLeadMilliseconds;
}

function nextPollAt(snapshot: TripSnapshot, now: number): number {
  const nextEvent = snapshot.stops
    .filter((stop) => !stop.passed)
    .map(eventTime)
    .filter((value): value is number => value !== null && value > now)
    .sort((left, right) => left - right)[0];
  if (nextEvent === undefined) return now + 15 * 60_000;
  const lead = nextEvent - now;
  if (lead > 2 * 60 * 60_000) return now + 60 * 60_000;
  if (lead > 45 * 60_000) return now + 30 * 60_000;
  return now + 15 * 60_000;
}

function complete(snapshot: TripSnapshot): boolean {
  return snapshot.stops.length > 0 && snapshot.stops.every((stop) => stop.passed);
}

export class PlatformCorpusSampler {
  constructor(
    private readonly persistence: PlatformCorpusSamplingPersistence,
    private readonly providers: ProviderRegistry,
    private readonly now: () => Date = () => new Date(),
  ) {}

  async run(): Promise<PlatformSamplingRunReport> {
    const now = this.now().getTime();
    const report: PlatformSamplingRunReport = {
      discoveryAttempted: false,
      targetsEnrolled: 0,
      targetsPolled: 0,
      observationsRecorded: 0,
      failures: 0,
    };
    const targets = this.persistence.duePlatformSamples(now, maximumPollsPerRun);
    const state = this.persistence.samplingState(now);
    if (state.discoveryDue && state.canEnroll && targets.length < maximumPollsPerRun) {
      report.discoveryAttempted = true;
      try {
        const target = await this.discover(now);
        if (target !== null) {
          targets.push(target);
          report.targetsEnrolled += 1;
        }
      } catch {
        report.failures += 1;
      }
    }

    for (const target of targets.slice(0, maximumPollsPerRun)) {
      try {
        const snapshot = await this.providers.fetchTrip(target);
        if (!approvedDELFIReference(snapshot.nativeId)) throw new Error("Unapproved platform sample source");
        report.observationsRecorded += this.persistence.recordPlatformSampleSuccess(
          target,
          snapshot,
          nextPollAt(snapshot, now),
          complete(snapshot),
          now,
        );
        report.targetsPolled += 1;
      } catch (error) {
        this.persistence.recordPlatformSampleFailure(target, error, now);
        report.failures += 1;
      }
    }
    this.persistence.recordPlatformSamplingRun(report, now);
    return report;
  }

  private async discover(now: number): Promise<PlatformSampleTarget | null> {
    const stations = await this.providers.searchStations("international", stationQuery);
    const station = exactFocusStation(stations);
    if (station === null) return null;
    const entries = await this.providers.fetchBoard({
      stationId: station.id,
      source: station.source,
      nativeId: station.nativeId,
      at: new Date(now).toISOString(),
      direction: "departures",
    });
    const entry = entries.find((candidate) => eligibleEntry(
      candidate,
      now,
      (id) => this.persistence.platformSampleSeen(id),
    ));
    const departure = entry === undefined ? null : departureTime(entry);
    if (entry === undefined || departure === null) return null;
    return this.persistence.enrollPlatformSample(entry.trip, departure, now);
  }
}
