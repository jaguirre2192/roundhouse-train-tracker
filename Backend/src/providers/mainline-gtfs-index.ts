import { z } from "zod";

export const gtfsRailCountries = ["TW","KR"] as const;
export type GTFSRailCountry = typeof gtfsRailCountries[number];
export const maximumGTFSRailIndexBytes = 8 * 1024 * 1024;
export const gtfsRailSources = {
  TW: {
    url: "https://github.com/jcanizalez/tdx-gtfs-mirror/releases/download/latest/tw-gtfs.zip",
    timeZone: "Asia/Taipei", utcOffsetHours: 8, agencies: ["TRA", "THSR"],
    attribution: "Ministry of Transportation and Communications Transportation Data Circulation Service Platform",
    licence: "Open Government Data License 1.0; TDX terms",
  },
  KR: {
    url: "https://mkuran.pl/gtfs/korail.zip", timeZone: "Asia/Seoul", utcOffsetHours: 9,
    agencies: ["korail"], attribution: "To Mikołaj Kuranowski", licence: "CC BY 4.0",
  },
} as const;

export const validGTFSDate = (value: string): boolean => /^\d{4}-\d{2}-\d{2}$/u.test(value)
  && Number.isFinite(Date.parse(`${value}T00:00:00Z`))
  && new Date(`${value}T00:00:00Z`).toISOString().slice(0, 10) === value;
const id = z.string().min(1).max(160);
const date = z.string().refine(validGTFSDate);
const second = z.number().int().min(0).max(72 * 3600).nullable();
const call = z.tuple([z.number().int().nonnegative(), z.number().int().min(0).max(1000), second, second, z.boolean(), z.boolean()]);
const schema = z.object({
  schemaVersion: z.literal(1), country: z.enum(gtfsRailCountries),
  sourceURL: z.string().url().max(1000), sourceHash: z.string().regex(/^[a-f0-9]{64}$/u),
  compiledAt: z.string().datetime(), validFrom: date, validUntil: date,
  stations: z.array(z.object({ id, name: z.string().min(1).max(200), latitude: z.number().min(-90).max(90),
    longitude: z.number().min(-180).max(180), agency: id, aliases: z.array(z.string().max(200)).max(16) })).min(2).max(2000),
  services: z.array(z.array(date).min(1).max(100)).min(1).max(10000),
  trips: z.array(z.object({ id, agency: id, product: z.string().min(1).max(200),
    service: z.number().int().nonnegative(), calls: z.array(call).min(2).max(200) })).min(1).max(10000),
}).strict();
export type GTFSRailIndex = z.infer<typeof schema>;
export type GTFSRailTrip = GTFSRailIndex["trips"][number];
export type GTFSRailStation = GTFSRailIndex["stations"][number];

/** Validates authenticated publications too; a broken refresh cannot replace a good timetable. */
export function parseGTFSRailIndex(value: unknown, country: GTFSRailCountry): GTFSRailIndex | null {
  const result = schema.safeParse(value);
  if (!result.success || result.data.country !== country) return null;
  const index = result.data, agencies: readonly string[] = gtfsRailSources[country].agencies;
  if (index.validUntil < index.validFrom || index.stations.some(s => !agencies.includes(s.agency))
    || new Set(index.stations.map(s => s.id)).size !== index.stations.length) return null;
  const identities = new Set<string>(); let count = 0;
  for (const dates of index.services) {
    if (new Set(dates).size !== dates.length || dates.some(d => d < index.validFrom || d > index.validUntil)) return null;
  }
  for (const trip of index.trips) {
    const dates = index.services[trip.service];
    if (!dates || !agencies.includes(trip.agency)) return null;
    let priorSequence = -1, priorTime = -1;
    for (const [station, sequence, arrival, departure] of trip.calls) {
      if (++count > 300000 || !index.stations[station] || sequence <= priorSequence
        || index.stations[station]!.agency !== trip.agency) return null;
      priorSequence = sequence;
      for (const time of [arrival, departure]) {
        if (time === null) continue;
        if (time < priorTime) return null;
        priorTime = time;
      }
    }
    if (trip.calls[0]![3] === null || trip.calls.at(-1)![2] === null) return null;
    for (const day of dates) {
      const key = `${trip.id}\u001f${day}`;
      if (identities.has(key)) return null;
      identities.add(key);
    }
  }
  return index;
}
