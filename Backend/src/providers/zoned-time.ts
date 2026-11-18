const formatters = new Map<string, Intl.DateTimeFormat>();

function formatter(timeZone: string): Intl.DateTimeFormat {
  let value = formatters.get(timeZone);
  if (value === undefined) {
    value = new Intl.DateTimeFormat("en-CA", {
      timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hourCycle: "h23",
    });
    formatters.set(timeZone, value);
  }
  return value;
}

export interface ZonedParts {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
  second: number;
}

export function zonedParts(utcMilliseconds: number, timeZone: string): ZonedParts {
  const parts = Object.fromEntries(formatter(timeZone).formatToParts(new Date(utcMilliseconds))
    .filter((part) => part.type !== "literal")
    .map((part) => [part.type, Number(part.value)]));
  return {
    year: parts.year!,
    month: parts.month!,
    day: parts.day!,
    hour: parts.hour!,
    minute: parts.minute!,
    second: parts.second!,
  };
}

function offsetAt(utcMilliseconds: number, timeZone: string): number {
  const parts = zonedParts(utcMilliseconds, timeZone);
  return Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second)
    - Math.floor(utcMilliseconds / 1000) * 1000;
}

// Converts a wall-clock time in `timeZone` to a UTC instant. A time skipped by a
// spring-forward gap resolves to the later offset; a repeated autumn hour resolves
// to its first occurrence.
export function zonedWallClockToUTC(
  timeZone: string,
  year: number,
  month: number,
  day: number,
  hour: number,
  minute: number,
  second = 0,
): number {
  const wallClock = Date.UTC(year, month - 1, day, hour, minute, second);
  const first = wallClock - offsetAt(wallClock - offsetAt(wallClock, timeZone), timeZone);
  const earlier = wallClock - offsetAt(first - 3_600_000, timeZone);
  return zonedParts(earlier, timeZone).hour === hour && earlier < first ? earlier : first;
}

// Resolves a provider "HH:mm[:ss]" clock time to the instant nearest `anchor`,
// considering the station's local day before, of, and after the anchor.
export function nearestZonedClockTime(
  timeZone: string,
  clock: string,
  anchorMilliseconds: number,
): number | null {
  const parsed = clock.match(/^(\d{2}):(\d{2})(?::(\d{2}))?$/u);
  if (parsed === null || !Number.isFinite(anchorMilliseconds)) return null;
  const hour = Number(parsed[1]);
  const minute = Number(parsed[2]);
  const second = Number(parsed[3] ?? 0);
  if (hour > 23 || minute > 59 || second > 59) return null;
  const anchorDay = zonedParts(anchorMilliseconds, timeZone);
  let closest: number | null = null;
  for (const dayOffset of [-1, 0, 1]) {
    const date = new Date(Date.UTC(anchorDay.year, anchorDay.month - 1, anchorDay.day + dayOffset));
    const candidate = zonedWallClockToUTC(
      timeZone,
      date.getUTCFullYear(),
      date.getUTCMonth() + 1,
      date.getUTCDate(),
      hour,
      minute,
      second,
    );
    if (closest === null || Math.abs(candidate - anchorMilliseconds) < Math.abs(closest - anchorMilliseconds)) {
      closest = candidate;
    }
  }
  return closest;
}
