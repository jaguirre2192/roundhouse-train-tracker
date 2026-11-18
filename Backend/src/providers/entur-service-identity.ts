import type { TripSnapshot } from "../domain/snapshot.js";

export function enturServiceJourneyId(snapshot: TripSnapshot): string | null {
  // Transitous keeps the complete Entur ID after its feed/date prefix. Never
  // infer a journey from a line number: services in both directions share it.
  const match = /^(?:(?:(\d{8})_\d{2}:\d{2}_)?no-Entur_)?([A-Z0-9]+:ServiceJourney:[^\s]+)$/u.exec(snapshot.nativeId);
  if (match === null || !/^\d{4}-\d{2}-\d{2}$/u.test(snapshot.serviceDate)) return null;
  const date = Date.parse(`${snapshot.serviceDate}T00:00:00Z`);
  if (!Number.isFinite(date) || new Date(date).toISOString().slice(0, 10) !== snapshot.serviceDate) return null;
  if (match[1] !== undefined && match[1] !== snapshot.serviceDate.replaceAll("-", "")) return null;
  return match[2] ?? null;
}
