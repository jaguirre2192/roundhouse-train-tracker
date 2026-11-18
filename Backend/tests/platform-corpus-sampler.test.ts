import { describe, expect, it } from "vitest";
import type { BoardEntrySnapshot, BoardReference, DiscoveryScope, StationSnapshot } from "../src/domain/discovery.js";
import type {
  PlatformCorpusSamplingPersistence,
  PlatformSampleTarget,
  PlatformSamplingRunReport,
} from "../src/domain/platform-sampling.js";
import type { CanonicalTripReference, TripSnapshot } from "../src/domain/snapshot.js";
import { PlatformCorpusSampler } from "../src/services/platform-corpus-sampler.js";
import { ProviderRegistry, type RailProvider } from "../src/providers/provider.js";

const now = Date.parse("2026-08-23T08:00:00.000Z");
const station: StationSnapshot = {
  id: "eu:transitous:de-DELFI_berlin-hbf",
  source: "transitous",
  nativeId: "de-DELFI_berlin-hbf",
  name: "Berlin Hbf",
  countryCode: "DE",
  latitude: 52.525,
  longitude: 13.369,
  operatorHints: [],
};
const approvedTrip: CanonicalTripReference = {
  id: "eu:transitous:20260823_08:32_de-DELFI_ice-507",
  source: "transitous",
  nativeId: "20260823_08:32_de-DELFI_ice-507",
  serviceDate: "2026-08-23",
};

class SamplingProvider implements RailProvider {
  readonly source = "transitous" as const;
  readonly discoveryScope: DiscoveryScope = "international";
  fetched: CanonicalTripReference[] = [];

  async searchStations(): Promise<StationSnapshot[]> { return [station]; }

  async fetchBoard(_reference: BoardReference): Promise<BoardEntrySnapshot[]> {
    return [{
      trip: {
        id: "eu:transitous:unlicensed",
        source: "transitous",
        nativeId: "20260823_08:20_other-feed_train",
        serviceDate: "2026-08-23",
      },
      stop: samplingSnapshot(approvedTrip).stops[0]!,
      headsign: "München Hbf",
      product: "ICE 505",
    }, {
      trip: approvedTrip,
      stop: samplingSnapshot(approvedTrip).stops[0]!,
      headsign: "München Hbf",
      product: "ICE 507",
    }];
  }

  async fetchTrip(reference: CanonicalTripReference): Promise<TripSnapshot> {
    this.fetched.push(reference);
    return samplingSnapshot(reference);
  }
}

class SamplingStore implements PlatformCorpusSamplingPersistence {
  target: PlatformSampleTarget | null = null;
  reports: PlatformSamplingRunReport[] = [];
  recorded: TripSnapshot[] = [];

  samplingState() { return { discoveryDue: true, canEnroll: true }; }
  platformSampleSeen(id: string) { return this.target?.id === id; }
  duePlatformSamples() { return [] as PlatformSampleTarget[]; }
  enrollPlatformSample(reference: CanonicalTripReference, _departureAt: number, enrolledAt: number) {
    this.target = { ...reference, expiresAt: enrolledAt + 36 * 60 * 60_000 };
    return this.target;
  }
  recordPlatformSampleSuccess(
    _target: PlatformSampleTarget,
    snapshot: TripSnapshot,
    _nextPollAt: number,
    _complete: boolean,
    _recordedAt: number,
  ) {
    this.recorded.push(snapshot);
    return 1;
  }
  recordPlatformSampleFailure() {}
  recordPlatformSamplingRun(report: PlatformSamplingRunReport) { this.reports.push(report); }
}

function samplingSnapshot(reference: CanonicalTripReference): TripSnapshot {
  return {
    ...reference,
    operatorName: "DB Fernverkehr AG",
    product: "ICE 507",
    headsign: "München Hbf",
    fetchedAt: "2026-08-23T08:00:00.000Z",
    alertIds: [],
    stops: [{
      stationId: station.id,
      stationName: station.name,
      countryCode: "DE",
      latitude: station.latitude,
      longitude: station.longitude,
      sequence: 1,
      scheduledArrival: "2026-08-23T08:25:00.000Z",
      scheduledDeparture: "2026-08-23T08:27:00.000Z",
      expectedArrival: "2026-08-23T08:25:00.000Z",
      expectedDeparture: "2026-08-23T08:27:00.000Z",
      plannedPlatform: "3",
      expectedPlatform: "3",
      platformSource: "DB Timetables",
      platformObservedAt: "2026-08-23T08:00:00.000Z",
      cancelled: false,
      passed: false,
    }],
  };
}

describe("platform corpus sampler", () => {
  it("enrolls only the rights-cleared DELFI/DB focus service and records its first snapshot", async () => {
    const provider = new SamplingProvider();
    const store = new SamplingStore();
    const sampler = new PlatformCorpusSampler(
      store,
      new ProviderRegistry([provider]),
      () => new Date(now),
    );

    const report = await sampler.run();

    expect(store.target).toMatchObject(approvedTrip);
    expect(provider.fetched).toHaveLength(1);
    expect(provider.fetched[0]).toMatchObject(approvedTrip);
    expect(store.recorded).toHaveLength(1);
    expect(report).toEqual({
      discoveryAttempted: true,
      targetsEnrolled: 1,
      targetsPolled: 1,
      observationsRecorded: 1,
      failures: 0,
    });
  });
});
