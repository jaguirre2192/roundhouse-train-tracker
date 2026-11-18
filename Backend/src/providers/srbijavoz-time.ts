import { srbijaVozTimeZone } from "./srbijavoz-stations.js";
import { zonedParts, zonedWallClockToUTC } from "./zoned-time.js";

export function validSrbijaVozDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/u.test(value)) return false;
  const parsed = new Date(`${value}T12:00:00Z`);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}

export function srbijaVozDateAt(instant: string | number): string {
  const milliseconds = typeof instant === "string" ? Date.parse(instant) : instant;
  if (!Number.isFinite(milliseconds)) throw new Error("Invalid Srbijavoz date");
  const parts = zonedParts(milliseconds, srbijaVozTimeZone);
  return `${parts.year}-${String(parts.month).padStart(2, "0")}-${String(parts.day).padStart(2, "0")}`;
}

export function shiftSrbijaVozDate(date: string, days: number): string {
  if (!validSrbijaVozDate(date) || !Number.isInteger(days)) throw new Error("Invalid Srbijavoz date");
  const value = new Date(`${date}T12:00:00Z`);
  value.setUTCDate(value.getUTCDate() + days);
  return value.toISOString().slice(0, 10);
}

export function srbijaVozClockMinutes(clock: string): number {
  const match = /^(\d{2}):([0-5]\d)$/u.exec(clock);
  if (match === null || Number(match[1]) > 23) throw new Error("Invalid Srbijavoz time");
  return Number(match[1]) * 60 + Number(match[2]);
}

export function srbijaVozInstant(date: string, clock: string): string {
  if (!validSrbijaVozDate(date)) throw new Error("Invalid Srbijavoz date");
  const minutes = srbijaVozClockMinutes(clock);
  const [year, month, day] = date.split("-").map(Number) as [number, number, number];
  const hour = Math.floor(minutes / 60);
  const minute = minutes % 60;
  const instant = zonedWallClockToUTC(srbijaVozTimeZone, year, month, day, hour, minute);
  const actual = zonedParts(instant, srbijaVozTimeZone);
  // Reject a spring-forward clock that never existed. Repeated autumn times use
  // the existing zoned-time helper's first occurrence, then chronology is checked.
  if (actual.year !== year || actual.month !== month || actual.day !== day
    || actual.hour !== hour || actual.minute !== minute) throw new Error("Invalid Srbijavoz wall clock");
  return new Date(instant).toISOString();
}

export function srbijaVozFallbackDeadline(serviceDate: string): number {
  return Date.parse(srbijaVozInstant(shiftSrbijaVozDate(serviceDate, 2), "00:00"));
}
