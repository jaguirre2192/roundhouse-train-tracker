export interface IrishRailStation {
  code: string;
  name: string;
  latitude: number | null;
  longitude: number | null;
}

export interface IrishRailBoardRow {
  trainCode: string;
  trainDate: string;
  origin: string;
  destination: string;
  status: string;
  scheduledArrival: string;
  scheduledDeparture: string;
}

export interface IrishRailMovement {
  locationName: string;
  locationType: string;
  scheduledArrival: string;
  scheduledDeparture: string;
  expectedArrival: string;
  expectedDeparture: string;
}

export interface IrishRailRun {
  trainCode: string;
  trainDate: string;
  originCode: string;
  destinationCode: string;
  originTime: string;
  status: string;
  latitude: number | null;
  longitude: number | null;
}
