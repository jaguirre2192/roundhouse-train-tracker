export type TdxRailSystem = "TRA" | "THSR";

export interface TdxName {
  Zh_tw?: string | null;
  En?: string | null;
}

export interface TdxPosition {
  PositionLat: number;
  PositionLon: number;
}

export interface TdxStation {
  StationID: string;
  StationName: TdxName;
  StationPosition?: TdxPosition | null;
}

export interface TdxStopTime {
  StopSequence: number;
  StationID: string;
  StationName: TdxName;
  ArrivalTime?: string | null;
  DepartureTime?: string | null;
  SuspendedFlag?: number | null;
}

export interface TdxTrainInfo {
  TrainNo: string;
  EndingStationName?: TdxName | null;
  TrainTypeCode?: string | null;
  TrainTypeName?: TdxName | null;
  SuspendedFlag?: number | null;
}

export interface TdxDailyTimetable {
  TrainDate: string;
  DailyTrainInfo: TdxTrainInfo;
  StopTimes: TdxStopTime[];
}

export interface TdxBoardRow extends TdxTrainInfo {
  TrainDate: string;
  StationID: string;
  StationName: TdxName;
  ArrivalTime?: string | null;
  DepartureTime?: string | null;
}

// TRA v3 wraps arrays and puts the date on the envelope. THSR v2 returns arrays.
export interface TraDailyTrains {
  TrainDate: string;
  TrainTimetables: { TrainInfo: TdxTrainInfo; StopTimes: TdxStopTime[] }[];
}

export interface TraDailyBoard {
  TrainDate: string;
  StationTimetables: {
    StationID: string;
    StationName: TdxName;
    TimeTables: (TdxTrainInfo & Pick<TdxStopTime, "ArrivalTime" | "DepartureTime"> & {
      DestinationStationName?: TdxName | null;
    })[];
  }[];
}

interface TraReport {
  TrainNo: string;
  StationID: string;
  UpdateTime?: string | null;
  DelayTime?: number | null;
}

export interface TraStationReport extends TraReport {
  ScheduleArrivalTime?: string | null;
  ScheduleDepartureTime?: string | null;
  Platform?: string | null;
  RunningStatus?: number | null;
}

export interface TraTrainReport extends TraReport {
  TrainStationStatus?: number | null;
}
