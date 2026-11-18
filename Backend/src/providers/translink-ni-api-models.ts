export interface TranslinkNIInfoLink {
  urlText?: string;
  subtitle?: string;
  title?: string;
  content?: string;
}

export interface TranslinkNIInfo {
  id?: string;
  version?: number;
  type?: string;
  infoLinks?: TranslinkNIInfoLink[];
}

export interface TranslinkNILocation {
  id: string;
  name: string;
  type: string;
  coord?: number[];
  productClasses?: number[];
  parent?: TranslinkNILocation;
  properties?: Record<string, unknown>;
  realtimeStatus?: string[];
  arrivalTimePlanned?: string;
  departureTimePlanned?: string;
  arrivalTimeEstimated?: string;
  departureTimeEstimated?: string;
  infos?: TranslinkNIInfo[];
}

export interface TranslinkNITransportation {
  id: string;
  name?: string;
  number?: string;
  description?: string;
  product?: {
    class?: number;
    name?: string;
  };
  operator?: {
    code?: string;
    id?: string;
    name?: string;
  };
  destination?: Pick<TranslinkNILocation, "id" | "name" | "type">;
  origin?: Pick<TranslinkNILocation, "id" | "name" | "type">;
  properties?: Record<string, unknown>;
}

export interface TranslinkNILeg {
  isRealtimeControlled?: boolean;
  realtimeStatus?: string[];
  origin: TranslinkNILocation;
  destination: TranslinkNILocation;
  transportation: TranslinkNITransportation;
  stopSequence?: TranslinkNILocation[];
  infos?: TranslinkNIInfo[];
  properties?: Record<string, unknown>;
}

export interface TranslinkNIJourney {
  interchanges?: number;
  legs?: TranslinkNILeg[];
  infos?: TranslinkNIInfo[];
}

export interface TranslinkNIStopFinderResponse {
  locations?: TranslinkNILocation[];
}

export interface TranslinkNITripResponse {
  journeys?: TranslinkNIJourney[];
}
