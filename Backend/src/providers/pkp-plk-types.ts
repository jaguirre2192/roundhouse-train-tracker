export interface PLKStation { id: number; name: string | null }
export interface PLKStationsResponse { stations?: PLKStation[] | null }

export interface PLKRouteStop {
  stationId: number;
  orderNumber: number;
  arrivalTrainNumber?: string | null;
  arrivalPlatform?: string | null;
  arrivalTrack?: string | null;
  arrivalDay?: number | null;
  arrivalTime?: string | null;
  departureTrainNumber?: string | null;
  departurePlatform?: string | null;
  departureTrack?: string | null;
  departureDay?: number | null;
  departureTime?: string | null;
}

export interface PLKRoute {
  scheduleId: number;
  orderId: number;
  trainOrderId?: number | null;
  name?: string | null;
  nationalNumber?: string | null;
  internationalArrivalNumber?: string | null;
  internationalDepartureNumber?: string | null;
  commercialCategorySymbol?: string | null;
  operatingDates?: string[] | null;
  stations?: PLKRouteStop[] | null;
}

export interface PLKScheduleResponse {
  generatedAt: string;
  routes?: PLKRoute[] | null;
  dictionaries?: { stations?: Record<string, PLKStation> | null } | null;
}

export interface PLKOperationStop {
  stationId: number;
  plannedArrival?: string | null;
  plannedDeparture?: string | null;
  arrivalDelayMinutes?: number | null;
  departureDelayMinutes?: number | null;
  actualArrival?: string | null;
  actualDeparture?: string | null;
  isCancelled: boolean;
}

export interface PLKOperation {
  scheduleId: number;
  orderId: number;
  trainOrderId?: number | null;
  operatingDate: string;
  trainStatus?: string | null;
  stations?: PLKOperationStop[] | null;
}

export interface PLKOperationsResponse {
  generatedAt: string;
  trains?: PLKOperation[] | null;
}

export interface PLKAffectedRoute {
  scheduleId: number;
  orderId: number;
  trainOrderId?: number | null;
  operatingDate: string;
  stationId: number;
}

export interface PLKDisruption {
  disruptionId: number;
  startStationId?: number | null;
  endStationId?: number | null;
  affectedRoutes?: PLKAffectedRoute[] | null;
}

export interface PLKDisruptionsResponse {
  disruptions?: PLKDisruption[] | null;
}
