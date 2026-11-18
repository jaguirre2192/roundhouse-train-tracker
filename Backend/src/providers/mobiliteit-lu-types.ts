export type HafasValue = string | number | boolean | null | undefined;

export interface MobiliteitPlatform {
  text?: HafasValue;
  hidden?: HafasValue;
}

export interface MobiliteitProduct {
  name?: HafasValue;
  displayNumber?: HafasValue;
  num?: HafasValue;
  line?: HafasValue;
  catOut?: HafasValue;
  catOutS?: HafasValue;
  catOutL?: HafasValue;
  catCode?: HafasValue;
}

export interface MobiliteitMessage {
  id?: HafasValue;
  externalId?: HafasValue;
  act?: HafasValue;
  head?: HafasValue;
  lead?: HafasValue;
  text?: HafasValue;
}

export interface MobiliteitStopLocation {
  id?: HafasValue;
  extId?: HafasValue;
  name?: HafasValue;
  lat?: HafasValue;
  lon?: HafasValue;
  dist?: HafasValue;
}

export interface MobiliteitPassStop extends MobiliteitStopLocation {
  routeIdx?: HafasValue;
  arrTime?: HafasValue;
  arrDate?: HafasValue;
  arrTz?: HafasValue;
  depTime?: HafasValue;
  depDate?: HafasValue;
  depTz?: HafasValue;
  rtArrTime?: HafasValue;
  rtArrDate?: HafasValue;
  rtArrTz?: HafasValue;
  rtDepTime?: HafasValue;
  rtDepDate?: HafasValue;
  rtDepTz?: HafasValue;
  arrTrack?: HafasValue;
  depTrack?: HafasValue;
  rtArrTrack?: HafasValue;
  rtDepTrack?: HafasValue;
  arrTrackHidden?: HafasValue;
  depTrackHidden?: HafasValue;
  rtArrTrackHidden?: HafasValue;
  rtDepTrackHidden?: HafasValue;
  arrPlatform?: MobiliteitPlatform;
  depPlatform?: MobiliteitPlatform;
  rtArrPlatform?: MobiliteitPlatform;
  rtDepPlatform?: MobiliteitPlatform;
  cancelled?: HafasValue;
  cancelledArrival?: HafasValue;
  cancelledDeparture?: HafasValue;
}

export interface MobiliteitDeparture extends MobiliteitStopLocation {
  time?: HafasValue;
  date?: HafasValue;
  tz?: HafasValue;
  track?: HafasValue;
  trackHidden?: HafasValue;
  rtTime?: HafasValue;
  rtDate?: HafasValue;
  rtTz?: HafasValue;
  rtTrack?: HafasValue;
  rtTrackHidden?: HafasValue;
  cancelled?: HafasValue;
  partCancelled?: HafasValue;
  JourneyStatus?: HafasValue;
  direction?: HafasValue;
  ProductAtStop?: MobiliteitProduct;
  Product?: MobiliteitProduct | MobiliteitProduct[];
  Stops?: { Stop?: MobiliteitPassStop | MobiliteitPassStop[] };
  Messages?: { Message?: MobiliteitMessage | MobiliteitMessage[] };
}

export interface MobiliteitLocationResponse {
  errorCode?: string;
  errorText?: string;
  StopLocation?: MobiliteitStopLocation | MobiliteitStopLocation[];
  stopLocationOrCoordLocation?: Array<{
    StopLocation?: MobiliteitStopLocation;
  }>;
}

export interface MobiliteitDepartureResponse {
  errorCode?: string;
  errorText?: string;
  Departure?: MobiliteitDeparture | MobiliteitDeparture[];
}
