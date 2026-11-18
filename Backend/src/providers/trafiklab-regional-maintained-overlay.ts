import type { TripSnapshot, VehiclePositionSnapshot } from "../domain/snapshot.js";
import type { PlatformObservation, PlatformRealtimeOverlay } from "./platform-overlay.js";
import type { RegionalRailIndex } from "./trafiklab-regional-index.js";
import { TrafiklabRegionalIndexSource, type RegionalIndexSourceOptions } from "./trafiklab-regional-index-source.js";
import { TrafiklabRegionalRealtimeOverlay, type TrafiklabRegionalOptions } from "./trafiklab-regional-realtime.js";
import { TrafiklabRegionalPositionOverlay, type RegionalPositionCallbacks } from "./trafiklab-regional-positions.js";
import type { TripPositionOverlay } from "./trip-position-overlay.js";

type Options = Omit<TrafiklabRegionalOptions, "index"> & RegionalIndexSourceOptions & Partial<RegionalPositionCallbacks>;
interface ActiveOverlays {
  index: RegionalRailIndex;
  overlay: TrafiklabRegionalRealtimeOverlay;
  positions: TrafiklabRegionalPositionOverlay | null;
}

/** Rotates only the compiled timetable; all generations share one quota gate. */
export class TrafiklabRegionalMaintainedOverlay implements PlatformRealtimeOverlay, TripPositionOverlay {
  readonly sourceName = "Trafiklab GTFS Regional — Skåne rail";
  readonly supportedCountryCodes = new Set(["SE"]);
  private readonly source: TrafiklabRegionalIndexSource;
  private active: ActiveOverlays | null = null;

  constructor(private readonly apiKey: string, private readonly options: Options) {
    this.source = new TrafiklabRegionalIndexSource(options);
  }

  health() {
    return { configured: this.apiKey.length > 0, index: this.source.health(), realtime: this.active?.overlay.health() ?? null,
      positions: this.active?.positions?.health() ?? null };
  }

  async platformUpdates(snapshot: TripSnapshot): Promise<PlatformObservation[]> {
    return (await this.getActive(snapshot))?.overlay.platformUpdates(snapshot) ?? [];
  }

  async positionUpdates(snapshot: TripSnapshot): Promise<VehiclePositionSnapshot[]> {
    if (this.options.reservePositionRequest === undefined) return [];
    return (await this.getActive(snapshot))?.positions?.positionUpdates(snapshot) ?? [];
  }

  private async getActive(snapshot: TripSnapshot): Promise<ActiveOverlays | null> {
    if (!snapshot.nativeId.includes("se-Trafiklab_") || !snapshot.stops.some((stop) => stop.countryCode.toUpperCase() === "SE")) return null;
    const index = await this.source.get();
    if (index === null) { this.active = null; return null; }
    if (this.active?.index !== index) {
      this.active = { index, overlay: new TrafiklabRegionalRealtimeOverlay(this.apiKey, { ...this.options, index }),
        positions: this.options.reservePositionRequest === undefined ? null
          : new TrafiklabRegionalPositionOverlay(this.apiKey, { ...this.options, index, reservePositionRequest: this.options.reservePositionRequest }) };
    }
    return this.active;
  }
}
