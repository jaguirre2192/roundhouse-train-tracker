// Compact offline GTFS data; no ZIP or national timetable enters the Worker.
// Stop identity uses the regional parent station's name and coordinates.
export type RegionalRailStation = readonly [stopId: string, parentId: string, name: string, latitude: number, longitude: number, platform: string];
export type RegionalRailCall = readonly [station: number, sequence: number, arrival: number, departure: number];
export type RegionalRailTrip = readonly [tripId: string, trainNumber: string, service: number, calls: readonly RegionalRailCall[]];
export interface RegionalRailIndex {
  operator: string;
  feedVersion: string;
  generatedAt: string;
  expiresAt: string;
  sourceHashes: Readonly<Record<string, string>>;
  stations: readonly RegionalRailStation[];
  services: readonly (readonly string[])[];
  trips: readonly RegionalRailTrip[];
}
