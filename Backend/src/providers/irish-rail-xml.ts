import type {
  IrishRailBoardRow,
  IrishRailMovement,
  IrishRailRun,
  IrishRailStation,
} from "./irish-rail-types.js";

interface XMLElement {
  body: string;
}

const months: Record<string, number> = {
  jan: 1,
  feb: 2,
  mar: 3,
  apr: 4,
  may: 5,
  jun: 6,
  jul: 7,
  aug: 8,
  sep: 9,
  oct: 10,
  nov: 11,
  dec: 12,
};

function decodeXML(value: string): string {
  return value
    .replaceAll("&quot;", "\"")
    .replaceAll("&apos;", "'")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&amp;", "&");
}

function elements(xml: string, tag: string): XMLElement[] {
  const expression = new RegExp(`<${tag}\\b[^>]*>([\\s\\S]*?)<\\/${tag}>|<${tag}\\b[^>]*/>`, "giu");
  return [...xml.matchAll(expression)].map((match) => ({ body: match[1] ?? "" }));
}

function value(xml: string, tag: string): string {
  const result = elements(xml, tag)[0]?.body.replace(/<[^>]+>/gu, "").trim() ?? "";
  return decodeXML(result);
}

function numeric(value: string): number | null {
  const trimmed = value.trim();
  if (trimmed.length === 0) return null;
  const result = Number(trimmed);
  return Number.isFinite(result) ? result : null;
}

export function apiDate(value: string): string | null {
  const match = value.trim().match(/^(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})$/u);
  if (match === null) return null;
  const month = months[match[2]!.toLowerCase()];
  return month === undefined
    ? null
    : `${match[3]}-${String(month).padStart(2, "0")}-${String(match[1]).padStart(2, "0")}`;
}

export function parseIrishRailStations(xml: string): IrishRailStation[] {
  return elements(xml, "objStation").flatMap((element): IrishRailStation[] => {
    const code = value(element.body, "StationCode");
    const name = value(element.body, "StationDesc");
    if (code.length === 0 || name.length === 0) return [];
    return [{
      code,
      name,
      latitude: numeric(value(element.body, "StationLatitude")),
      longitude: numeric(value(element.body, "StationLongitude")),
    }];
  });
}

export function parseIrishRailBoard(xml: string): IrishRailBoardRow[] {
  return elements(xml, "objStationData").flatMap((element): IrishRailBoardRow[] => {
    const trainCode = value(element.body, "Traincode");
    if (trainCode.length === 0) return [];
    return [{
      trainCode,
      trainDate: value(element.body, "Traindate"),
      origin: value(element.body, "Origin"),
      destination: value(element.body, "Destination"),
      status: value(element.body, "Status"),
      scheduledArrival: value(element.body, "Scharrival"),
      scheduledDeparture: value(element.body, "Schdepart"),
    }];
  });
}

export function parseIrishRailMovements(xml: string): IrishRailMovement[] {
  return elements(xml, "objTrainMovements").flatMap((element): IrishRailMovement[] => {
    const locationName = value(element.body, "LocationFullName");
    if (locationName.length === 0) return [];
    return [{
      locationName,
      locationType: value(element.body, "LocationType"),
      scheduledArrival: value(element.body, "ScheduledArrival"),
      scheduledDeparture: value(element.body, "ScheduledDeparture"),
      expectedArrival: value(element.body, "ExpectedArrival"),
      expectedDeparture: value(element.body, "ExpectedDeparture"),
    }];
  });
}

export function parseIrishRailRuns(xml: string): IrishRailRun[] {
  return elements(xml, "objHaconPositions").flatMap((element): IrishRailRun[] => {
    const trainCode = value(element.body, "TrainCode");
    if (trainCode.length === 0) return [];
    return [{
      trainCode,
      trainDate: value(element.body, "TrainDate"),
      originCode: value(element.body, "TrainOrigin"),
      destinationCode: value(element.body, "TrainDestination"),
      originTime: value(element.body, "TrainOriginTime"),
      status: value(element.body, "TrainStatus"),
      latitude: numeric(value(element.body, "TrainLatitude")),
      longitude: numeric(value(element.body, "TrainLongitude")),
    }];
  });
}
