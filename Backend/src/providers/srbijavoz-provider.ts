import type { BoardEntrySnapshot, BoardReference, StationSnapshot } from "../domain/discovery.js";
import type { RailPlaceSnapshot } from "../domain/journey.js";
import type { CanonicalTripReference, TripSnapshot } from "../domain/snapshot.js";
import {
  JourneyProviderUnavailableError, type JourneySearchProvider,
  type ProviderJourneySearchRequest, type ProviderJourneySearchResult,
} from "./journey-provider.js";
import { RailProviderNotFoundError, type RailProvider } from "./provider.js";
import { RailProviderUnavailableError } from "./rail-provider-error.js";
import { decodeRailPlaceId, type DecodedRailPlaceId } from "./rail-place-id.js";
import { SrbijaVozAPI } from "./srbijavoz-api.js";
import { decodeSrbijaVozTrip } from "./srbijavoz-identity.js";
import { mapSrbijaVozConnection, type SrbijaVozMappedConnection } from "./srbijavoz-mapper.js";
import { retainedSrbijaVozSnapshot } from "./srbijavoz-retained-snapshot.js";
import { searchSrbijaVozStations, srbijaVozAttributions, srbijaVozPlace, srbijaVozStationForPlace } from "./srbijavoz-stations.js";
import { shiftSrbijaVozDate, srbijaVozDateAt } from "./srbijavoz-time.js";

export interface SrbijaVozSnapshotStore {
  get(key: string): Promise<TripSnapshot | undefined>;
  put(key: string, snapshot: TripSnapshot): Promise<void>;
}

export interface SrbijaVozProviderOptions {
  fetcher?: typeof fetch;
  now?: () => Date;
  snapshotStore?: SrbijaVozSnapshotStore;
}

class MemorySnapshotStore implements SrbijaVozSnapshotStore {
  private readonly values = new Map<string, TripSnapshot>();
  async get(key: string) { return structuredClone(this.values.get(key)); }
  async put(key: string, value: TripSnapshot) {
    if (this.values.size >= 256 && !this.values.has(key)) this.values.delete(this.values.keys().next().value!);
    this.values.set(key, structuredClone(value));
  }
}

export class SrbijaVozProvider implements RailProvider, JourneySearchProvider {
  readonly source = "srbijavoz" as const;
  readonly discoveryScope = "international" as const;
  private readonly api: SrbijaVozAPI;
  private readonly now: () => Date;
  private readonly snapshots: SrbijaVozSnapshotStore;

  constructor(options: SrbijaVozProviderOptions = {}) {
    this.now = options.now ?? (() => new Date());
    this.api = new SrbijaVozAPI(options.fetcher, this.now);
    this.snapshots = options.snapshotStore ?? new MemorySnapshotStore();
  }

  handlesPlace(place: DecodedRailPlaceId): boolean { return srbijaVozStationForPlace(place) !== undefined; }

  toTransitousPlace(place: DecodedRailPlaceId): DecodedRailPlaceId {
    const station = srbijaVozStationForPlace(place);
    return station === undefined ? place : { ...place, provider: "transitous", nativeId: station.transitousId };
  }

  async searchStations(_query: string): Promise<StationSnapshot[]> {
    // Journey-only discovery until a complete official station-board API exists.
    return [];
  }

  async fetchBoard(_reference: BoardReference): Promise<BoardEntrySnapshot[]> {
    throw new RailProviderUnavailableError("Complete Srbijavoz station boards are unavailable");
  }

  async searchPlaces(query: string, limit: number): Promise<RailPlaceSnapshot[]> {
    if (!Number.isFinite(limit) || limit <= 0) return [];
    return searchSrbijaVozStations(query).slice(0, Math.floor(limit)).map(srbijaVozPlace);
  }

  async searchJourneys(input: ProviderJourneySearchRequest): Promise<ProviderJourneySearchResult> {
    const from = srbijaVozStationForPlace(decodeRailPlaceId(input.originId));
    const to = srbijaVozStationForPlace(decodeRailPlaceId(input.destinationId));
    if (from === undefined || to === undefined || from.code === to.code || input.providerCursor !== null) {
      throw new JourneyProviderUnavailableError("Unsupported Srbijavoz journey request");
    }
    try {
      const day = srbijaVozDateAt(input.time);
      const dates = input.arriveBy ? [shiftSrbijaVozDate(day, -1), day] : [day, shiftSrbijaVozDate(day, 1)];
      const mapped: SrbijaVozMappedConnection[] = [];
      // Sequential and cached: do not burst requests at the public ticket service.
      for (const serviceDate of dates) {
        const timetable = await this.api.connections(from.code, to.code, serviceDate);
        for (const row of timetable.connections) {
          const connection = mapSrbijaVozConnection(row, serviceDate, timetable.fetchedAt);
          if (connection !== null) mapped.push(connection);
        }
      }
      const requested = Date.parse(input.time);
      const eligible = mapped.filter(({ option }) => input.arriveBy
        ? Date.parse(option.endTime) <= requested : Date.parse(option.startTime) >= requested)
        .sort((a, b) => Date.parse(a.option.startTime) - Date.parse(b.option.startTime));
      const selected = input.arriveBy ? eligible.slice(-20) : eligible.slice(0, 20);
      for (const value of selected) await this.snapshots.put(value.snapshot.id, value.snapshot);
      const fastest = Math.min(...selected.map(({ option }) => option.duration));
      return {
        options: selected.map(({ option }) => ({ ...option,
          badges: option.duration === fastest ? [...option.badges, "fastest"] : option.badges })),
        previousProviderCursor: null, nextProviderCursor: null, attributions: [...srbijaVozAttributions],
      };
    } catch (error) {
      if (error instanceof JourneyProviderUnavailableError) throw error;
      throw new JourneyProviderUnavailableError("Srbijavoz timetable is unavailable");
    }
  }

  async fetchTrip(reference: CanonicalTripReference): Promise<TripSnapshot> {
    const identity = decodeSrbijaVozTrip(reference);
    if (identity === null) throw new RailProviderNotFoundError();
    let upstreamError: unknown;
    try {
      const timetable = await this.api.connections(identity.from, identity.to, identity.serviceDate);
      const rows = timetable.connections.filter((row) => row.idvoz === identity.trainId
        && row.brvoz === identity.trainNumber && row.vremep === identity.departure);
      if (rows.length === 1) {
        const mapped = mapSrbijaVozConnection(rows[0]!, identity.serviceDate, timetable.fetchedAt);
        if (mapped !== null && mapped.snapshot.id === reference.id) {
          await this.snapshots.put(reference.id, mapped.snapshot);
          return structuredClone(mapped.snapshot);
        }
      }
    } catch (error) { upstreamError = error; }
    const previous = retainedSrbijaVozSnapshot(await this.snapshots.get(reference.id), reference, identity, this.now().getTime());
    if (previous !== null) return previous;
    if (upstreamError !== undefined) throw upstreamError;
    throw new RailProviderNotFoundError();
  }
}
