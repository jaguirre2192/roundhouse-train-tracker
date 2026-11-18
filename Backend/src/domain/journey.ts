export type RailPlaceKind = "city" | "station";

export interface GeoCoordinateSnapshot {
  latitude: number;
  longitude: number;
}

export interface RailPlaceSnapshot {
  id: string;
  kind: RailPlaceKind;
  displayName: string;
  context: string;
  countryCode: string;
  timeZoneIdentifier: string;
  location: GeoCoordinateSnapshot;
  eligibleModes: string[];
  attributions: string[];
}

export interface JourneyCallSnapshot {
  place: RailPlaceSnapshot;
  city: RailPlaceSnapshot | null;
  scheduledArrival: string | null;
  scheduledDeparture: string | null;
  expectedArrival: string | null;
  expectedDeparture: string | null;
  plannedPlatform: string | null;
  expectedPlatform: string | null;
  isCancelled: boolean;
}

export interface RailJourneySegmentSnapshot {
  tripId: string | null;
  serviceDate: string;
  operatorName: string;
  product: string;
  trainNumber: string | null;
  trainName: string | null;
  from: JourneyCallSnapshot;
  to: JourneyCallSnapshot;
  intermediateCalls: JourneyCallSnapshot[];
  isCancelled: boolean;
  isRealtime: boolean;
  isTrackable: boolean;
  untrackableReason: string | null;
}

export interface WalkJourneySegmentSnapshot {
  from: RailPlaceSnapshot;
  to: RailPlaceSnapshot;
  duration: number;
  distance: number | null;
  isStationChange: boolean;
}

export type JourneySegmentSnapshot =
  | {
      id: string;
      kind: "rail";
      rail: RailJourneySegmentSnapshot;
      walk: null;
    }
  | {
      id: string;
      kind: "walk";
      rail: null;
      walk: WalkJourneySegmentSnapshot;
    };

export type JourneyBadge = "direct" | "fastest" | "fewestChanges";

export interface JourneyTrackabilitySnapshot {
  trackableRailSegments: number;
  totalRailSegments: number;
}

export interface JourneyOptionSnapshot {
  id: string;
  fingerprint: string;
  startTime: string;
  endTime: string;
  duration: number;
  transferCount: number;
  segments: JourneySegmentSnapshot[];
  badges: JourneyBadge[];
  trackability: JourneyTrackabilitySnapshot;
  realtimeFreshness: string | null;
  attributions: string[];
  trackingToken: string;
}

export interface JourneySearchRequest {
  originId: string;
  destinationId: string;
  time: string;
  arriveBy: boolean;
  maxTransfers: number;
  cursor: string | null;
}

export interface JourneySearchPageSnapshot {
  generatedAt: string;
  expiresAt: string;
  options: JourneyOptionSnapshot[];
  previousCursor: string | null;
  nextCursor: string | null;
  warnings: string[];
  attributions: string[];
}
