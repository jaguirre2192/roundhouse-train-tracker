import type { EkispertText, EkispertValue } from "./ekispert-types.js";

export function values<Value>(value: Value | Value[] | undefined): Value[] {
  if (value === undefined) return [];
  return Array.isArray(value) ? value : [value];
}

export function valueText(value: EkispertValue | undefined): string | null {
  if (value === undefined) return null;
  if (typeof value === "string" || typeof value === "number") return String(value).trim() || null;
  return value.text?.trim() || null;
}

export function dictionary(valuesToIndex: EkispertValue | EkispertValue[] | undefined): Map<string, string> {
  const result = new Map<string, string>();
  for (const value of values(valuesToIndex)) {
    if (typeof value !== "object") continue;
    const text = valueText(value);
    if (value.code !== undefined && text !== null) result.set(value.code, text);
  }
  return result;
}

export function operation(value: EkispertValue | undefined): EkispertText["operation"] | undefined {
  return typeof value === "object" ? value.operation : undefined;
}

export function isJapanMainlineName(value: EkispertValue | undefined): boolean {
  const name = valueText(value)?.normalize("NFKC") ?? "";
  return /(新幹線|特急|寝台|shinkansen|limited express|sleeper)/iu.test(name);
}

export function japanDate(value: Date): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "Asia/Tokyo",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(value);
  const part = (type: Intl.DateTimeFormatPartTypes) => parts.find((item) => item.type === type)?.value ?? "";
  return `${part("year")}-${part("month")}-${part("day")}`;
}

export function compactDate(value: string): string {
  return value.replaceAll("-", "");
}

export function scheduledTime(serviceDate: string, hour: string, minute: string): string {
  const timestamp = new Date(`${serviceDate}T00:00:00+09:00`);
  timestamp.setUTCMinutes(timestamp.getUTCMinutes() + Number(hour) * 60 + Number(minute));
  return timestamp.toISOString();
}

export function clockTime(serviceDate: string, value: EkispertValue | undefined): string | null {
  const time = valueText(value);
  if (time === null) return null;
  const match = /^(\d{1,2}):(\d{2})(?::(\d{2}))?/u.exec(time);
  if (match === null) return null;
  const timestamp = new Date(`${serviceDate}T00:00:00+09:00`);
  timestamp.setUTCSeconds(
    timestamp.getUTCSeconds()
      + Number(match[1]) * 3_600
      + Number(match[2]) * 60
      + Number(match[3] ?? "0"),
  );
  if (operation(value) === "yesterday") timestamp.setUTCDate(timestamp.getUTCDate() - 1);
  return timestamp.toISOString();
}
