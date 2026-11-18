import { z } from "zod";
import type { CanonicalTripReference, TripSnapshot } from "../domain/snapshot.js";
import type { SrbijaVozTripIdentity } from "./srbijavoz-identity.js";
import { srbijaVozFallbackDeadline, srbijaVozInstant } from "./srbijavoz-time.js";

const timestamp = z.string().datetime({ offset: true });
const stopSchema = z.object({
  stationId: z.string().regex(/^rs:srbijavoz:[1-9]\d*$/u),
  stationName: z.string().trim().min(1).max(160),
  countryCode: z.string().regex(/^[A-Z]{2}$/u),
  latitude: z.number().finite().min(-90).max(90).nullable(),
  longitude: z.number().finite().min(-180).max(180).nullable(),
  sequence: z.number().int().positive(),
  scheduledArrival: timestamp.nullable(),
  scheduledDeparture: timestamp.nullable(),
});
const snapshotSchema = z.object({
  id: z.string(), source: z.literal("srbijavoz"), nativeId: z.string(), serviceDate: z.string(),
  operatorName: z.literal("Srbijavoz"), product: z.string(), headsign: z.string(), fetchedAt: timestamp,
  stops: z.array(stopSchema).min(2).max(150),
});

export function retainedSrbijaVozSnapshot(
  value: unknown,
  reference: CanonicalTripReference,
  identity: SrbijaVozTripIdentity,
  now: number,
): TripSnapshot | null {
  const parsed = snapshotSchema.safeParse(value);
  if (!parsed.success) return null;
  const previous = parsed.data;
  if (previous.id !== reference.id || previous.nativeId !== reference.nativeId
    || previous.serviceDate !== reference.serviceDate || reference.source !== "srbijavoz"
    || Date.parse(previous.fetchedAt) > now || now >= srbijaVozFallbackDeadline(identity.serviceDate)
    || !new RegExp(`^(?:Soko )?(?:IC|IR|Re|REx) ${identity.trainNumber}$`, "u").test(previous.product)
    || previous.headsign !== previous.stops.at(-1)!.stationName) return null;
  const origins = previous.stops.flatMap((stop, index) => stop.stationId === `rs:srbijavoz:${identity.from}` ? [index] : []);
  const destinations = previous.stops.flatMap((stop, index) => stop.stationId === `rs:srbijavoz:${identity.to}` ? [index] : []);
  if (origins.length !== 1 || destinations.length !== 1 || origins[0]! >= destinations[0]!) return null;
  const origin = previous.stops[origins[0]!]!;
  const destination = previous.stops[destinations[0]!]!;
  let departure: string;
  try { departure = srbijaVozInstant(identity.serviceDate, identity.departure); } catch { return null; }
  if (origin.countryCode !== "RS" || destination.countryCode !== "RS"
    || origin.scheduledDeparture !== departure || destination.scheduledArrival === null) return null;
  const duration = Date.parse(destination.scheduledArrival) - Date.parse(departure);
  if (duration <= 0 || duration > 12 * 60 * 60_000) return null;
  let last = -Infinity;
  for (const [index, stop] of previous.stops.entries()) {
    if (stop.sequence !== index + 1 || (stop.latitude === null) !== (stop.longitude === null)
      || (stop.scheduledArrival === null && stop.scheduledDeparture === null)) return null;
    for (const time of [stop.scheduledArrival, stop.scheduledDeparture]) {
      if (time === null) continue;
      const instant = Date.parse(time);
      if (!Number.isFinite(instant) || instant < last) return null;
      last = instant;
    }
  }
  const first = previous.stops[0]!;
  const final = previous.stops.at(-1)!;
  if (first.scheduledArrival !== null || first.scheduledDeparture === null
    || final.scheduledDeparture !== null || final.scheduledArrival === null
    || Date.parse(final.scheduledArrival) - Date.parse(first.scheduledDeparture) > 36 * 60 * 60_000) return null;
  // Reconstruct from validated schedule fields: no cached realtime, geometry,
  // platform forecast or fresh observation timestamp can leak into this fallback.
  return {
    ...previous,
    stops: previous.stops.map((stop) => ({ ...stop,
      expectedArrival: null, expectedDeparture: null, plannedPlatform: null, expectedPlatform: null,
      platformSource: null, platformObservedAt: null, cancelled: false, passed: false,
    })),
    alertIds: [],
  };
}
