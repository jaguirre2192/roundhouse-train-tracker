import type { StopSnapshot, TripSnapshot, VehiclePositionSnapshot } from "./snapshot.js";

interface Coordinate { latitude: number; longitude: number }
interface Projection { distance: number; offset: number }
export interface RoutePositionEvidence {
  arrived: boolean;
  focus: StopSnapshot | null;
  isClearlyBeforeDestination: boolean;
}

function valid(value: { latitude: number | null; longitude: number | null }): value is Coordinate {
  return value.latitude !== null && value.longitude !== null
    && Number.isFinite(value.latitude) && Math.abs(value.latitude) <= 90
    && Number.isFinite(value.longitude) && Math.abs(value.longitude) <= 180
    && (value.latitude !== 0 || value.longitude !== 0);
}

function distance(a: Coordinate, b: Coordinate): number {
  return Math.hypot((b.latitude - a.latitude) * 111_195,
    (b.longitude - a.longitude) * 111_195 * Math.cos((a.latitude + b.latitude) * Math.PI / 360));
}

function geometry(trip: TripSnapshot): Coordinate[] {
  if (trip.routeGeometry === undefined) return trip.stops.flatMap((stop) => valid(stop)
    ? [{ latitude: stop.latitude, longitude: stop.longitude }] : []);
  const result: Coordinate[] = [];
  for (const segment of trip.routeGeometry.segments) {
    if (!Number.isInteger(segment.precision) || segment.precision < 0 || segment.precision > 7
      || !Number.isInteger(segment.pointCount) || segment.pointCount < 2 || segment.pointCount > 100_000) continue;
    let index = 0;
    let latitude = 0;
    let longitude = 0;
    const points: Coordinate[] = [];
    const component = (): number | null => {
      let value = 0;
      for (let shift = 0; shift <= 30 && index < segment.encodedPolyline.length; shift += 5) {
        const byte = segment.encodedPolyline.charCodeAt(index++) - 63;
        if (byte < 0 || byte > 63) return null;
        value += (byte & 31) * 2 ** shift;
        if (byte < 32) return value % 2 === 1 ? -(value + 1) / 2 : value / 2;
      }
      return null;
    };
    while (index < segment.encodedPolyline.length && points.length < segment.pointCount) {
      const dy = component(), dx = component();
      if (dy === null || dx === null) break;
      latitude += dy; longitude += dx;
      const point = { latitude: latitude / 10 ** segment.precision, longitude: longitude / 10 ** segment.precision };
      if (!valid(point)) break;
      points.push(point);
    }
    if (index !== segment.encodedPolyline.length || points.length !== segment.pointCount) continue;
    for (const point of points) {
      const previous = result.at(-1);
      if (previous?.latitude !== point.latitude || previous.longitude !== point.longitude) result.push(point);
    }
  }
  return result;
}

/** Mirrors Core RailRoutePositionEvidence: route order, bounded offsets and loop rejection. */
export function routePositionEvidence(
  trip: TripSnapshot, stops: StopSnapshot[], position: VehiclePositionSnapshot,
): RoutePositionEvidence | null {
  const first = stops[0];
  const departure = first?.expectedDeparture ?? first?.scheduledDeparture ?? first?.expectedArrival ?? first?.scheduledArrival;
  if (stops.length < 2 || !stops.every(valid) || departure == null
    || !(Date.parse(position.asOf) >= Date.parse(departure))) return null;
  // Missing full-route coordinates cannot safely connect separated selected stations.
  if (trip.routeGeometry === undefined && !trip.stops.every(valid)) return null;
  const coordinates = geometry(trip);
  if (coordinates.length < 2 || !coordinates.every(valid)) return null;
  const cumulative = [0];
  for (let i = 1; i < coordinates.length; i++) {
    const a = coordinates[i - 1]!, b = coordinates[i]!;
    if (Math.abs(a.longitude - b.longitude) >= 180) return null;
    cumulative.push(cumulative[i - 1]! + distance(a, b));
  }
  if (cumulative.at(-1)! <= 100) return null;
  const project = (target: Coordinate): Projection | null => {
    const candidates: Projection[] = [];
    for (let i = 0; i < coordinates.length - 1; i++) {
      const a = coordinates[i]!, b = coordinates[i + 1]!;
      const scale = 111_195 * Math.cos(target.latitude * Math.PI / 180);
      const ax = (a.longitude - target.longitude) * scale, ay = (a.latitude - target.latitude) * 111_195;
      const dx = (b.longitude - a.longitude) * scale, dy = (b.latitude - a.latitude) * 111_195;
      const lengthSquared = dx * dx + dy * dy;
      if (lengthSquared <= 0) continue;
      const fraction = Math.min(1, Math.max(0, -(ax * dx + ay * dy) / lengthSquared));
      candidates.push({ distance: cumulative[i]! + (cumulative[i + 1]! - cumulative[i]!) * fraction,
        offset: Math.hypot(ax + fraction * dx, ay + fraction * dy) });
    }
    const best = candidates.reduce<Projection | null>((a, b) => a === null || b.offset < a.offset ? b : a, null);
    if (best === null || candidates.some((value) => value.offset <= best.offset + 150
      && Math.abs(value.distance - best.distance) > 1_000)) return null;
    return best;
  };
  const fix = project(position);
  const projections = stops.map((stop) => project(stop as Coordinate));
  if (fix === null || fix.offset > 2_000 || projections.some((value) => value === null || value.offset > 1_000)
    || projections.some((value, index) => index > 0 && value!.distance - projections[index - 1]!.distance <= 100)) return null;
  const destination = projections.at(-1)!;
  const arrived = !stops.at(-1)!.cancelled && fix.distance > destination.distance + 500;
  return { arrived, isClearlyBeforeDestination: fix.distance < destination.distance - 500,
    focus: arrived ? null : stops.find((stop, index) => !stop.cancelled && projections[index]!.distance + 500 >= fix.distance) ?? null };
}
