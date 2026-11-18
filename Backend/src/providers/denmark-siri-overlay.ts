import type { TripSnapshot } from "../domain/snapshot.js";
import { denmarkSiriObservations, denmarkSiriTrainNumber, isDenmarkSiriEligibleSnapshot } from "./denmark-siri-matching.js";
import { denmarkSiriSourceName, type DenmarkSiriJourney } from "./denmark-siri-models.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";

/** Reads committed event state only. Interactive requests never consume the broker. */
export class DenmarkSiriOverlay implements PlatformRealtimeOverlay {
  readonly sourceName = denmarkSiriSourceName;
  readonly supportedCountryCodes = new Set(["DK"]);

  constructor(
    private readonly load: (snapshot: TripSnapshot, nowISO: string) => Promise<DenmarkSiriJourney[]>,
    private readonly now: () => Date = () => new Date(),
  ) {}

  async platformUpdates(snapshot: TripSnapshot): Promise<PlatformObservation[]> {
    if (!isDenmarkSiriEligibleSnapshot(snapshot) || denmarkSiriTrainNumber(snapshot) === null) return [];
    const now = this.now();
    return denmarkSiriObservations(snapshot, await this.load(snapshot, now.toISOString()), now);
  }
}
