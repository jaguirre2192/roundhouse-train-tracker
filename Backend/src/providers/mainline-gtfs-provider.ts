import { createHash } from "node:crypto";
import type { BoardEntrySnapshot, BoardReference, StationSnapshot } from "../domain/discovery.js";
import type { JourneyCallSnapshot, JourneyOptionSnapshot, RailPlaceSnapshot } from "../domain/journey.js";
import type { CanonicalTripReference, StopSnapshot, TripSnapshot } from "../domain/snapshot.js";
import { gtfsRailCountries, gtfsRailSources, parseGTFSRailIndex, validGTFSDate, type GTFSRailCountry, type GTFSRailIndex, type GTFSRailStation, type GTFSRailTrip } from "./mainline-gtfs-index.js";
import { decodeRailPlaceId, encodeRailPlaceId, type DecodedRailPlaceId } from "./rail-place-id.js";
import { RailProviderNotFoundError, type RailProvider } from "./provider.js";
import { RailProviderUnavailableError } from "./rail-provider-error.js";
import type { JourneySearchProvider, ProviderJourneySearchRequest, ProviderJourneySearchResult } from "./journey-provider.js";

const aliases: Record<string, string[]> = {
  "臺北": ["Taipei"], "台北": ["Taipei"], "南港": ["Nangang"], "板橋": ["Banqiao"], "桃園": ["Taoyuan"],
  "新竹": ["Hsinchu"], "苗栗": ["Miaoli"], "臺中": ["Taichung"], "台中": ["Taichung"], "彰化": ["Changhua"],
  "雲林": ["Yunlin"], "嘉義": ["Chiayi"], "臺南": ["Tainan"], "台南": ["Tainan"], "左營": ["Zuoying", "Kaohsiung"],
  "新左營": ["Xinzuoying", "Kaohsiung"], "高雄": ["Kaohsiung"], "花蓮": ["Hualien"], "臺東": ["Taitung"], "台東": ["Taitung"],
};
const normalized = (value: string) => value.normalize("NFKD").replace(/\p{Diacritic}/gu, "").toLowerCase().trim();
export const gtfsNativePrefix = (country: GTFSRailCountry) => `ttgtfs:${country}:`;
export function gtfsCountryForNativeID(nativeId: string): GTFSRailCountry | null {
  return gtfsRailCountries.find(country => nativeId.startsWith(gtfsNativePrefix(country))) ?? null;
}

/** Uses the existing opaque Transitous wire namespace so shipped clients can resolve and save these trips. */
export class StaticGTFSProvider implements RailProvider, JourneySearchProvider {
  readonly source = "transitous" as const;
  readonly discoveryScope = "international" as const;
  private readonly now: () => Date;
  constructor(readonly country: GTFSRailCountry, private readonly loadIndex: () => Promise<unknown>, private readonly options: {
    now?: () => Date; realtime?: (snapshot: TripSnapshot,index: GTFSRailIndex,trip: GTFSRailTrip) => Promise<TripSnapshot>;
    realtimeBoard?: (entries: BoardEntrySnapshot[], reference: BoardReference) => Promise<BoardEntrySnapshot[]>;
  } = {}) {
    this.now = options.now ?? (() => new Date());
  }
  private async index(): Promise<GTFSRailIndex> {
    const index = parseGTFSRailIndex(await this.loadIndex(), this.country);
    if (!index) throw new RailProviderUnavailableError("Rail timetable is temporarily unavailable");
    return index;
  }
  private nativeStation(id: string) { return `${gtfsNativePrefix(this.country)}stop:${id}`; }
  private stationID(id: string) { return `eu:transitous:${this.nativeStation(id)}`; }
  private tripReference(trip: GTFSRailTrip, day: string): CanonicalTripReference {
    const nativeId = `${gtfsNativePrefix(this.country)}trip:${day}:${trip.id}`;
    return { source: this.source, nativeId, id: `eu:transitous:${nativeId}`, serviceDate: day };
  }
  private operatorName(agency: string) { return agency === "korail" ? "Korail" : agency === "THSR" ? "Taiwan High Speed Rail" : "Taiwan Railway (TRA)"; }
  private station(station: GTFSRailStation): StationSnapshot {
    return { id: this.stationID(station.id), source: this.source, nativeId: this.nativeStation(station.id),
      name: station.name, countryCode: this.country, latitude: station.latitude, longitude: station.longitude,
      operatorHints: [this.operatorName(station.agency), station.agency] };
  }
  private place(station: GTFSRailStation): RailPlaceSnapshot {
    return { id: encodeRailPlaceId({ provider: "transitous", kind: "station", nativeId: this.nativeStation(station.id),
      countryCode: this.country, latitude: null, longitude: null }), kind: "station", displayName: station.name,
      context: this.operatorName(station.agency), countryCode: this.country, timeZoneIdentifier: gtfsRailSources[this.country].timeZone,
      location: { latitude: station.latitude, longitude: station.longitude }, eligibleModes: ["REGIONAL"],
      attributions: [gtfsRailSources[this.country].attribution] };
  }
  handlesPlace(place: DecodedRailPlaceId): boolean {
    return place.provider === "transitous" && place.kind === "station" && place.countryCode === this.country
      && place.nativeId.startsWith(`${gtfsNativePrefix(this.country)}stop:`);
  }
  private matches(station: GTFSRailStation, query: string): boolean {
    return [station.name, ...station.aliases, ...(this.country === "TW" ? aliases[station.name] ?? [] : [])]
      .some(value => normalized(value).includes(query));
  }
  async searchStations(query: string): Promise<StationSnapshot[]> {
    const needle = normalized(query); if (!needle) return [];
    return (await this.index()).stations.filter(s => this.matches(s, needle)).slice(0,20).map(s => this.station(s));
  }
  async searchPlaces(query: string, limit: number): Promise<RailPlaceSnapshot[]> {
    const needle = normalized(query); if (!needle || !Number.isFinite(limit) || limit <= 0) return [];
    return (await this.index()).stations.filter(s => this.matches(s, needle)).slice(0,Math.floor(limit)).map(s => this.place(s));
  }
  private instant(day: string, seconds: number | null): string | null {
    return seconds === null ? null : new Date(Date.parse(`${day}T00:00:00Z`) + (seconds - gtfsRailSources[this.country].utcOffsetHours * 3600) * 1000).toISOString();
  }
  private datesAround(at: string): string[] {
    const local = Date.parse(at) + gtfsRailSources[this.country].utcOffsetHours * 3600000;
    if (!Number.isFinite(local)) return [];
    return [-3,-2,-1,0,1].map(offset => new Date(local + offset * 86400000).toISOString().slice(0,10));
  }
  private snapshot(index: GTFSRailIndex, trip: GTFSRailTrip, day: string): TripSnapshot {
    const stops = trip.calls.map(([position, sequence, arrival, departure], i): StopSnapshot => {
      const station = index.stations[position]!;
      return { stationId: this.stationID(station.id), stationName: station.name, countryCode: this.country,
        latitude: station.latitude, longitude: station.longitude, sequence,
        scheduledArrival: i === 0 ? null : this.instant(day,arrival), scheduledDeparture: i === trip.calls.length - 1 ? null : this.instant(day,departure),
        expectedArrival: null, expectedDeparture: null, plannedPlatform: null, expectedPlatform: null,
        platformSource: null, platformObservedAt: null, cancelled: false, passed: false };
    });
    return { ...this.tripReference(trip,day), operatorName: this.operatorName(trip.agency), product: trip.product,
      headsign: stops.at(-1)!.stationName, fetchedAt: this.now().toISOString(), stops, alertIds: [] };
  }
  async fetchTrip(reference: CanonicalTripReference): Promise<TripSnapshot> {
    if (reference.source !== this.source || !validGTFSDate(reference.serviceDate)) throw new RailProviderNotFoundError();
    const index = await this.index();
    const trip = index.trips.find(t => this.tripReference(t,reference.serviceDate).nativeId === reference.nativeId
      && this.tripReference(t,reference.serviceDate).id === reference.id && index.services[t.service]!.includes(reference.serviceDate));
    if (!trip) throw new RailProviderNotFoundError();
    const snapshot = this.snapshot(index,trip,reference.serviceDate);
    return this.options.realtime ? this.options.realtime(snapshot,index,trip) : snapshot;
  }
  async fetchBoard(reference: BoardReference): Promise<BoardEntrySnapshot[]> {
    const index = await this.index(), station = index.stations.find(s => this.nativeStation(s.id) === reference.nativeId);
    if (!station || reference.source !== this.source || reference.stationId !== this.stationID(station.id)) return [];
    const at = Date.parse(reference.at), days = this.datesAround(reference.at);
    if (!Number.isFinite(at)) return [];
    const localDay = days[3]!;
    if (localDay < index.validFrom || localDay > index.validUntil) throw new RailProviderUnavailableError("Requested date is outside the published timetable");
    // Already-due departures may still appear on a live board when delayed.
    const earliestSchedule = this.options.realtimeBoard ? at - 6 * 3_600_000 : at;
    const result: BoardEntrySnapshot[] = [];
    for (const trip of index.trips) for (const day of days) {
      if (!index.services[trip.service]!.includes(day)) continue;
      for (let i = 0; i < trip.calls.length; i++) {
        const call = trip.calls[i]!;
        if (index.stations[call[0]]!.id !== station.id || !(reference.direction === "departures" ? call[4] && i < trip.calls.length - 1 : call[5] && i > 0)) continue;
        const time = this.instant(day,reference.direction === "departures" ? call[3] : call[2]);
        if (!time || Date.parse(time) < earliestSchedule || Date.parse(time) >= at + 86400000) continue;
        const snapshot = this.snapshot(index,trip,day);
        result.push({ trip: this.tripReference(trip,day), stop: snapshot.stops[i]!, headsign: snapshot.headsign, product: snapshot.product });
      }
    }
    const entries = this.options.realtimeBoard ? await this.options.realtimeBoard(result, reference) : result;
    const departing = reference.direction === "departures";
    return entries.flatMap(entry => {
      const clock = departing ? entry.stop.expectedDeparture ?? entry.stop.scheduledDeparture
        : entry.stop.expectedArrival ?? entry.stop.scheduledArrival;
      if (!clock) return [];
      const time = Date.parse(clock);
      return time >= at && time < at + 86_400_000 ? [{ entry, time }] : [];
    }).sort((left, right) => left.time - right.time).slice(0, 100).map(({ entry }) => entry);
  }
  async searchJourneys(input: ProviderJourneySearchRequest): Promise<ProviderJourneySearchResult> {
    const origin = decodeRailPlaceId(input.originId), destination = decodeRailPlaceId(input.destinationId), index = await this.index();
    const from = index.stations.find(s => this.nativeStation(s.id) === origin.nativeId), to = index.stations.find(s => this.nativeStation(s.id) === destination.nativeId);
    if (!this.handlesPlace(origin) || !this.handlesPlace(destination) || !from || !to || input.providerCursor !== null) throw new RailProviderUnavailableError("Unsupported rail timetable search");
    const at = Date.parse(input.time), days = this.datesAround(input.time);
    if (!Number.isFinite(at) || days[3]! < index.validFrom || days[3]! > index.validUntil) throw new RailProviderUnavailableError("Requested date is outside the published timetable");
    const options: JourneyOptionSnapshot[] = [];
    for (const trip of index.trips) {
      const first = trip.calls.findIndex(c => index.stations[c[0]]!.id === from.id && c[4]);
      const last = trip.calls.findIndex((c,i) => i > first && index.stations[c[0]]!.id === to.id && c[5]);
      if (first < 0 || last <= first) continue;
      for (const day of days) {
        if (!index.services[trip.service]!.includes(day)) continue;
        const startTime = this.instant(day,trip.calls[first]![3]), endTime = this.instant(day,trip.calls[last]![2]);
        if (!startTime || !endTime || Date.parse(endTime) <= Date.parse(startTime)) continue;
        if (input.arriveBy ? Date.parse(endTime) > at || Date.parse(endTime) < at - 172800000
          : Date.parse(startTime) < at || Date.parse(startTime) > at + 172800000) continue;
        const snapshot = this.snapshot(index,trip,day);
        const call = (i: number): JourneyCallSnapshot => ({ place: this.place(index.stations[trip.calls[i]![0]]!), city: null,
          scheduledArrival: i === first ? null : snapshot.stops[i]!.scheduledArrival,
          scheduledDeparture: i === last ? null : snapshot.stops[i]!.scheduledDeparture,
          expectedArrival: null, expectedDeparture: null, plannedPlatform: null, expectedPlatform: null, isCancelled: false });
        const fingerprint = `journey-v1-${createHash("sha256").update(JSON.stringify([snapshot.id,from.id,to.id,startTime,endTime])).digest("hex")}`;
        options.push({ id: `journey-option-${fingerprint.slice(-24)}`, fingerprint, startTime, endTime,
          duration: (Date.parse(endTime) - Date.parse(startTime)) / 1000, transferCount: 0,
          segments: [{ id: `journey-segment-${fingerprint.slice(-24)}`, kind: "rail", walk: null, rail: {
            tripId: snapshot.id, serviceDate: day, operatorName: snapshot.operatorName, product: trip.product,
            trainNumber: trip.product.split(" ").at(-1) ?? null, trainName: null, from: call(first), to: call(last),
            intermediateCalls: trip.calls.slice(first+1,last).map((_,i) => call(first+i+1)),
            isCancelled: false, isRealtime: false, isTrackable: true, untrackableReason: null,
          } }], badges: ["direct","fewestChanges"], trackability: { trackableRailSegments: 1, totalRailSegments: 1 },
          realtimeFreshness: null, attributions: [gtfsRailSources[this.country].attribution], trackingToken: "" });
      }
    }
    options.sort((a,b) => a.startTime.localeCompare(b.startTime));
    return { options: input.arriveBy ? options.slice(-20) : options.slice(0,20), previousProviderCursor: null,
      nextProviderCursor: null, attributions: [gtfsRailSources[this.country].attribution] };
  }
}
