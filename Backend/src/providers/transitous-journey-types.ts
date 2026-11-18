export interface TransitousJourneyPlace {
  name: string;
  stopId?: string | null;
  country?: string | null;
  parentId?: string | null;
  lat: number;
  lon: number;
  tz?: string | null;
  arrival?: string | null;
  departure?: string | null;
  scheduledArrival?: string | null;
  scheduledDeparture?: string | null;
  scheduledTrack?: string | null;
  track?: string | null;
  cancelled?: boolean | null;
}

export interface TransitousLeg {
  mode: string;
  routeType?: number | null;
  from: TransitousJourneyPlace;
  to: TransitousJourneyPlace;
  duration?: number | null;
  distance?: number | null;
  startTime: string;
  endTime: string;
  scheduledStartTime?: string | null;
  scheduledEndTime?: string | null;
  realTime?: boolean | null;
  headsign?: string | null;
  agencyName?: string | null;
  tripId?: string | null;
  routeShortName?: string | null;
  routeLongName?: string | null;
  tripShortName?: string | null;
  displayName?: string | null;
  cancelled?: boolean | null;
  intermediateStops?: TransitousJourneyPlace[] | null;
}

export interface TransitousItinerary {
  id?: string | null;
  startTime: string;
  endTime: string;
  duration: number;
  transfers: number;
  legs: TransitousLeg[];
}

export interface TransitousPlanResponse {
  previousPageCursor?: string | null;
  nextPageCursor?: string | null;
  itineraries: TransitousItinerary[];
}
