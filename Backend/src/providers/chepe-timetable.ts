import { z } from "zod";

const weekdays = z.array(z.number().int().min(0).max(6)).min(1);
const stop = z.object({
  stationId: z.enum(["los-mochis", "el-fuerte", "bahuichivo", "divisadero", "creel"]),
  time: z.string().regex(/^(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d$/u),
});

const timetable = z.object({
  validFrom: z.iso.date(),
  validThrough: z.iso.date(),
  publicationSignatures: z.array(z.string().trim().min(1)).min(1),
  routes: z.array(z.object({
    nativeId: z.enum(["express-los-mochis-creel", "express-creel-los-mochis"]),
    headsign: z.string().trim().min(1),
    operatingDays: weekdays,
    suspensions: z.array(z.object({
      months: z.array(z.number().int().min(1).max(12)).min(1),
      weekdays,
    })).default([]),
    stops: z.array(stop).min(2),
  })).min(1),
}).refine(value => value.validFrom <= value.validThrough)
  .refine(value => new Set(value.routes.map(route => route.nativeId)).size === value.routes.length);

export type ChepeTimetable = z.infer<typeof timetable>;
export type ChepeRoute = ChepeTimetable["routes"][number];
export type ChepeRouteStop = ChepeRoute["stops"][number];

export function readChepeTimetable(input?: string): ChepeTimetable | null {
  if (!input) return null;
  try {
    const result = timetable.safeParse(JSON.parse(input));
    return result.success ? result.data : null;
  } catch {
    return null;
  }
}
