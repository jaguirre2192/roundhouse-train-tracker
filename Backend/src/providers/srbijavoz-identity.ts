import type { CanonicalTripReference } from "../domain/snapshot.js";
import { srbijaVozStation } from "./srbijavoz-stations.js";
import { srbijaVozClockMinutes, validSrbijaVozDate } from "./srbijavoz-time.js";

export interface SrbijaVozTripIdentity {
  serviceDate: string;
  trainId: number;
  trainNumber: number;
  from: number;
  to: number;
  departure: string;
}

export function srbijaVozTripReference(identity: SrbijaVozTripIdentity): CanonicalTripReference {
  const nativeId = ["v1", identity.serviceDate, identity.trainId, identity.trainNumber,
    identity.from, identity.to, identity.departure.replace(":", "")].join("_");
  return { id: `rs:srbijavoz:${nativeId}`, source: "srbijavoz", nativeId, serviceDate: identity.serviceDate };
}

export function decodeSrbijaVozTrip(reference: CanonicalTripReference): SrbijaVozTripIdentity | null {
  const match = /^v1_(\d{4}-\d{2}-\d{2})_([1-9]\d*)_([1-9]\d*)_([1-9]\d*)_([1-9]\d*)_(\d{4})$/u.exec(reference.nativeId);
  if (reference.source !== "srbijavoz" || match === null
    || reference.id !== `rs:srbijavoz:${reference.nativeId}`
    || reference.serviceDate !== match[1] || !validSrbijaVozDate(match[1]!)) return null;
  const [trainId, trainNumber, from, to] = match.slice(2, 6).map(Number) as [number, number, number, number];
  if (![trainId, trainNumber, from, to].every((value) => Number.isSafeInteger(value) && value > 0)
    || from === to || srbijaVozStation(from) === undefined || srbijaVozStation(to) === undefined) return null;
  const departure = `${match[6]!.slice(0, 2)}:${match[6]!.slice(2)}`;
  try { srbijaVozClockMinutes(departure); } catch { return null; }
  return { serviceDate: match[1]!, trainId, trainNumber, from, to, departure };
}
