import type { TripSnapshot } from "../domain/snapshot.js";
import { decodePolyline5, type PolylineCoordinate } from "./encoded-polyline.js";

function valid(value: { latitude: number | null; longitude: number | null }): value is PolylineCoordinate {
  return value.latitude !== null && value.longitude !== null && Number.isFinite(value.latitude)
    && Number.isFinite(value.longitude) && Math.abs(value.latitude) <= 90 && Math.abs(value.longitude) <= 180
    && (value.latitude !== 0 || value.longitude !== 0);
}
function distanceKm(a: PolylineCoordinate, b: PolylineCoordinate): number {
  const radians = Math.PI / 180;
  const h = Math.sin((b.latitude - a.latitude) * radians / 2) ** 2
    + Math.cos(a.latitude * radians) * Math.cos(b.latitude * radians)
    * Math.sin((b.longitude - a.longitude) * radians / 2) ** 2;
  return 12_742 * Math.asin(Math.min(1, Math.sqrt(h)));
}
function offsetKm(point: PolylineCoordinate, a: PolylineCoordinate, b: PolylineCoordinate): number {
  const xScale = 111.195 * Math.cos(point.latitude * Math.PI / 180);
  const ax = (a.longitude - point.longitude) * xScale, ay = (a.latitude - point.latitude) * 111.195;
  const dx = (b.longitude - a.longitude) * xScale, dy = (b.latitude - a.latitude) * 111.195;
  const square = dx * dx + dy * dy;
  const fraction = square === 0 ? 0 : Math.min(1, Math.max(0, -(ax * dx + ay * dy) / square));
  return Math.hypot(ax + fraction * dx, ay + fraction * dy);
}
function routeSegments(snapshot: TripSnapshot): PolylineCoordinate[][] {
  const segments = snapshot.routeGeometry?.segments ?? [];
  if (segments.length > 100) return [];
  return segments.flatMap(segment => {
    if (!Number.isInteger(segment.precision) || segment.precision < 0 || segment.precision > 7
      || !Number.isInteger(segment.pointCount) || segment.pointCount < 2 || segment.pointCount > 100_000
      || segment.encodedPolyline.length > 1_000_000) return [];
    const decoded = decodePolyline5(segment.encodedPolyline, segment.pointCount);
    if (decoded === null) return [];
    const scale = 10 ** (5 - segment.precision);
    const coordinates = decoded.map(point => ({ latitude: point.latitude * scale, longitude: point.longitude * scale }));
    return coordinates.every(valid) ? [coordinates] : [];
  });
}

export type MalaysiaPositionRejection = "before-origin" | "unreachable-from-origin" | "after-service-window" | "outside-route";

/** Reject clear contradictions, not modest timetable drift. These deliberately
 * generous bounds are plausibility checks, never affirmative GPS evidence. */
export function malaysiaPositionRejection(
  snapshot: TripSnapshot, point: PolylineCoordinate, observedAt: number,
): MalaysiaPositionRejection | null {
  const first = snapshot.stops[0], last = snapshot.stops.at(-1);
  const departure = Date.parse(first?.scheduledDeparture ?? first?.scheduledArrival ?? "");
  if (Number.isFinite(departure)) {
    // Even at 300 km/h, with 15 minutes of early-running tolerance and 10 km
    // location slack, a distant reused train number can be impossible to reach.
    const hours = (observedAt - departure + 15 * 60_000) / 3_600_000;
    if (hours < 0) return "before-origin";
    if (first !== undefined && valid(first) && distanceKm(first, point) > hours * 300 + 10) {
      return "unreachable-from-origin";
    }
  }
  const end = Math.max(...[last?.scheduledArrival, last?.scheduledDeparture, last?.expectedArrival, last?.expectedDeparture]
    .map(value => Date.parse(value ?? "")).filter(Number.isFinite));
  if (Number.isFinite(end) && observedAt > end + 6 * 60 * 60_000) return "after-service-window";
  const segments = routeSegments(snapshot);
  if (segments.length > 0) {
    let nearest = Number.POSITIVE_INFINITY;
    for (const segment of segments) {
      for (let index = 1; index < segment.length; index++) {
        nearest = Math.min(nearest, offsetKm(point, segment[index - 1]!, segment[index]!));
      }
    }
    if (nearest > 15) return "outside-route";
  }
  return null;
}
