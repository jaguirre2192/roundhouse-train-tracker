import type { StopSnapshot } from "../domain/snapshot.js";
import type { TdxName, TdxPosition, TdxRailSystem, TdxStation, TdxStopTime, TdxTrainInfo } from "./tdx-types.js";

export function tdxName(value: TdxName | null | undefined): string {
  return value?.En?.trim() || value?.Zh_tw?.trim() || "";
}

export function tdxNativeID(system: TdxRailSystem, value: string): string { return `${system}:${value}`; }

export function parseTdxNativeID(value: string): { system: TdxRailSystem; value: string } {
  const separator = value.indexOf(":");
  const system = value.slice(0, separator), nativeValue = value.slice(separator + 1);
  if ((system !== "TRA" && system !== "THSR") || !nativeValue) throw new Error(`Invalid TDX identifier ${value}`);
  return { system, value: nativeValue };
}

const day = 86_400_000;
const taipeiDateFormat = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Asia/Taipei", year: "numeric", month: "2-digit", day: "2-digit",
});
export function taiwanDate(value: Date): string { return taipeiDateFormat.format(value); }

export function tdxTimestamp(date: string, time: string | null | undefined): string | null {
  const clock = /^(\d{2}):([0-5]\d)(?::([0-5]\d))?$/u.exec(time ?? "");
  if (!clock || Number(clock[1]) >= 48) return null;
  const midnight = Date.parse(`${date}T00:00:00+08:00`);
  if (!Number.isFinite(midnight)) return null;
  const seconds = Number(clock[1]) * 3600 + Number(clock[2]) * 60 + Number(clock[3] ?? 0);
  return new Date(midnight + seconds * 1000).toISOString();
}

export function isIntercityTdxService(system: TdxRailSystem, value: TdxTrainInfo): boolean {
  if (system === "THSR") return true;
  if (["6", "7", "10"].includes(value.TrainTypeCode ?? "")) return false;
  const name = `${value.TrainTypeName?.En ?? ""} ${value.TrainTypeName?.Zh_tw ?? ""}`.toLowerCase();
  return !["local", "ordinary", "commuter", "區間", "普快", "普通", "通勤"].some(marker => name.includes(marker));
}

export function tdxProduct(system: TdxRailSystem, info: TdxTrainInfo): string {
  const product = system === "THSR" ? "THSR" : tdxName(info.TrainTypeName) || "TRA";
  return `${product} ${info.TrainNo}`;
}

export function tdxStationPosition(station: TdxStation | undefined): TdxPosition | null {
  const position = station?.StationPosition;
  if (!position || !Number.isFinite(position.PositionLat) || !Number.isFinite(position.PositionLon)
    || Math.abs(position.PositionLat) > 90 || Math.abs(position.PositionLon) > 180
    || (position.PositionLat === 0 && position.PositionLon === 0)) return null;
  return position;
}

export function tdxStops(
  system: TdxRailSystem, date: string, values: TdxStopTime[], stations: readonly TdxStation[], cancelled = false,
): StopSnapshot[] {
  const positions = new Map(stations.map(station => [station.StationID, tdxStationPosition(station)]));
  let previousTime = -Infinity;
  function followingTime(clock: string | null | undefined): string | null {
    const raw = tdxTimestamp(date, clock);
    if (!raw) return null;
    let time = Date.parse(raw);
    if (time < previousTime) time += Math.ceil((previousTime - time) / day) * day;
    previousTime = time;
    return new Date(time).toISOString();
  }
  return [...values].sort((left, right) => left.StopSequence - right.StopSequence).map(value => {
    const position = positions.get(value.StationID);
    return {
      stationId: `tw:tdx:${tdxNativeID(system, value.StationID)}`, stationName: tdxName(value.StationName),
      countryCode: "TW", latitude: position?.PositionLat ?? null, longitude: position?.PositionLon ?? null,
      sequence: value.StopSequence,
      scheduledArrival: followingTime(value.ArrivalTime), scheduledDeparture: followingTime(value.DepartureTime),
      expectedArrival: null, expectedDeparture: null, plannedPlatform: null, expectedPlatform: null,
      platformSource: null, platformObservedAt: null, cancelled: cancelled || value.SuspendedFlag === 1, passed: false,
    };
  });
}
