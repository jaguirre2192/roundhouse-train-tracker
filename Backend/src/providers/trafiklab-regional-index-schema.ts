import { z } from "zod";
import type { RegionalRailIndex } from "./trafiklab-regional-index.js";

export const maximumRegionalIndexBytes = 2 * 1_024 * 1_024;

const identifier = z.string().regex(/^\d{1,24}$/u);
const date = z.string().regex(/^\d{8}$/u);
const integer = z.number().int().nonnegative();
const schema = z.object({
  operator: z.literal("skane"),
  feedVersion: z.string().regex(/^\d{4}-\d{2}-\d{2}$/u),
  generatedAt: z.iso.datetime(), expiresAt: z.iso.datetime(),
  sourceHashes: z.object({ regional: z.string().regex(/^[a-f0-9]{64}$/u) }).strict(),
  stations: z.array(z.tuple([identifier, identifier, z.string().trim().min(1).max(160),
    z.number().min(-90).max(90), z.number().min(-180).max(180), z.string().max(32)])).min(2).max(2_500),
  services: z.array(z.array(date).min(1).max(32)).min(1).max(3_000),
  trips: z.array(z.tuple([identifier, z.string().regex(/^\d{1,8}$/u), integer.max(2_999),
    z.array(z.tuple([integer.max(2_499), z.number().int().positive().max(1_000), integer.max(172_800), integer.max(172_800)])).min(2).max(150),
  ])).min(1).max(10_000),
}).strict();

/** Validate both bounded shape and the references used for identity matching. */
export function parseRegionalRailIndex(value: unknown, now: Date): RegionalRailIndex | null {
  if (typeof value === "string") {
    if (value.length > maximumRegionalIndexBytes || new TextEncoder().encode(value).byteLength > maximumRegionalIndexBytes) return null;
    try { value = JSON.parse(value) as unknown; } catch { return null; }
  }
  const result = schema.safeParse(value);
  if (!result.success) return null;
  const index = result.data;
  const generated = Date.parse(index.generatedAt), expires = Date.parse(index.expiresAt), time = now.getTime();
  const day = 86_400_000;
  if (!Number.isFinite(time) || index.generatedAt !== `${index.feedVersion}T00:00:00.000Z`
    || new Date(generated).toISOString().slice(0, 10) !== index.feedVersion
    || expires !== generated + 7 * day || time < generated - 120_000 || time >= expires) return null;
  if (new Set(index.stations.map((station) => station[0])).size !== index.stations.length
    || new Set(index.trips.map((trip) => trip[0])).size !== index.trips.length) return null;
  const first = generated - day, last = generated + 30 * day;
  for (const dates of index.services) {
    let previous = "";
    for (const date of dates) {
      const iso = `${date.slice(0, 4)}-${date.slice(4, 6)}-${date.slice(6)}`;
      const value = Date.parse(`${iso}T00:00:00Z`);
      if (!Number.isFinite(value) || new Date(value).toISOString().slice(0, 10) !== iso
        || value < first || value >= last || date <= previous) return null;
      previous = date;
    }
  }
  let count = 0;
  for (const trip of index.trips) {
    if (trip[2] >= index.services.length || (count += trip[3].length) > 150_000) return null;
    let previousSequence = 0, previousDeparture = -1;
    const parents = new Set<string>();
    for (const [station, sequence, arrival, departure] of trip[3]) {
      if (station >= index.stations.length || sequence <= previousSequence || arrival < previousDeparture || departure < arrival) return null;
      parents.add(index.stations[station]![1]); previousSequence = sequence; previousDeparture = departure;
    }
    if (parents.size < 2) return null;
  }
  return index;
}

export function isRegionalRailIndexFresh(index: RegionalRailIndex, now: Date): boolean {
  const time = now.getTime();
  return Number.isFinite(time) && time >= Date.parse(index.generatedAt) - 120_000 && time < Date.parse(index.expiresAt);
}
