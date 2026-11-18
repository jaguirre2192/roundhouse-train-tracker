export interface EkispertText {
  text?: string;
  code?: string;
  operation?: "today" | "yesterday";
}

export type EkispertValue = string | number | EkispertText;

export interface EkispertStation {
  code: string;
  Name: string;
  Type?: string | { text?: string; detail?: string };
}

export interface EkispertPoint {
  GeoPoint?: {
    lati_d?: string;
    longi_d?: string;
  };
  Prefecture?: {
    code?: string;
    Name?: string;
  };
  Station: EkispertStation;
}

export interface EkispertStationResponse {
  ResultSet: {
    Point?: EkispertPoint | EkispertPoint[];
  };
}

export interface EkispertTimetableLine {
  Name: EkispertValue;
  Direction?: EkispertValue;
  Source?: EkispertValue;
}

export interface EkispertTimetableStop {
  lineCode: string;
  platformNo?: string;
  nameCode?: string;
  destinationCode?: string;
  kindCode?: string;
  Number?: EkispertValue;
}

export interface EkispertMinuteTable {
  Minute: EkispertValue;
  Stop: EkispertTimetableStop | EkispertTimetableStop[];
}

export interface EkispertHourTable {
  Hour: EkispertValue;
  MinuteTable: EkispertMinuteTable | EkispertMinuteTable[];
}

export interface EkispertTimetable {
  code: string;
  trainCount?: string;
  Station?: { Name?: string };
  Line: EkispertTimetableLine;
  HourTable?: EkispertHourTable | EkispertHourTable[];
  LineName?: EkispertValue | EkispertValue[];
  LineDestination?: EkispertValue | EkispertValue[];
  LineKind?: EkispertValue | EkispertValue[];
}

export interface EkispertTimetableResponse {
  ResultSet: {
    TimeTable?: EkispertTimetable | EkispertTimetable[];
  };
}

export interface EkispertState {
  Datetime?: EkispertValue;
}

export interface EkispertTripStop {
  Point: EkispertPoint;
  ArrivalState?: EkispertState;
  DepartureState?: EkispertState;
}

export interface EkispertTripLine {
  code?: string;
  Name: EkispertValue;
  Number?: EkispertValue;
  Stop: EkispertTripStop | EkispertTripStop[];
}

export interface EkispertTripResponse {
  ResultSet: {
    Line?: EkispertTripLine | EkispertTripLine[];
  };
}
