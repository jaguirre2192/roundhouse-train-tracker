import type { RouteGeometrySnapshot } from "../domain/snapshot.js";
import { decodePolyline5, encodePolyline5, type PolylineCoordinate } from "./encoded-polyline.js";
import type {
  NorthAmericanIntercityRouteGeometrySource,
  NorthAmericanIntercityRouteGeometryStop,
} from "./north-american-intercity-gtfs-geometry.js";
import { normalizedNorthAmericanIntercityOperator } from "./north-american-intercity-gtfs-model.js";
import {
  ntadAmtrakRoutesSourceLabel,
  type NTADAmtrakRouteNetworkData,
  type NTADRoute,
} from "./ntad-amtrak-routes-model.js";

/** A station further than this from every line of a route is not on that route. */
const stopSnapLimitMeters = 3_000;
/** Stops may sit just outside a route's stored bounds. */
const boundsMarginDegrees = 0.05;
const maximumPointCount = 100_000;

interface DecodedEdge {
  coordinates: PolylineCoordinate[];
  /** Distance from the start of the edge to each coordinate, in metres. */
  cumulative: number[];
  length: number;
}

interface Snap {
  use: number;
  /** Metres from the start of the edge. */
  offset: number;
  distance: number;
  point: PolylineCoordinate;
}

function distanceMeters(left: PolylineCoordinate, right: PolylineCoordinate): number {
  const radians = Math.PI / 180;
  const latitudeDelta = (right.latitude - left.latitude) * radians;
  const longitudeDelta = (right.longitude - left.longitude) * radians;
  const haversine = Math.sin(latitudeDelta / 2) ** 2
    + Math.cos(left.latitude * radians) * Math.cos(right.latitude * radians) * Math.sin(longitudeDelta / 2) ** 2;
  return 2 * 6_371_000 * Math.asin(Math.min(1, Math.sqrt(haversine)));
}

/** The nearest point to `target` on one edge, measured on a local flat projection. */
function nearestOnEdge(edge: DecodedEdge, target: PolylineCoordinate): { offset: number; distance: number; point: PolylineCoordinate } {
  const metersPerLongitude = 111_320 * Math.cos(target.latitude * Math.PI / 180);
  const metersPerLatitude = 110_540;
  let best = { offset: 0, distance: Number.POSITIVE_INFINITY, point: edge.coordinates[0]! };
  for (let index = 0; index < edge.coordinates.length - 1; index += 1) {
    const start = edge.coordinates[index]!;
    const end = edge.coordinates[index + 1]!;
    const startX = (start.longitude - target.longitude) * metersPerLongitude;
    const startY = (start.latitude - target.latitude) * metersPerLatitude;
    const deltaX = (end.longitude - start.longitude) * metersPerLongitude;
    const deltaY = (end.latitude - start.latitude) * metersPerLatitude;
    const lengthSquared = deltaX * deltaX + deltaY * deltaY;
    const fraction = lengthSquared === 0 ? 0 : Math.min(1, Math.max(0, -(startX * deltaX + startY * deltaY) / lengthSquared));
    const distance = Math.hypot(startX + fraction * deltaX, startY + fraction * deltaY);
    if (distance < best.distance) {
      const segmentLength = edge.cumulative[index + 1]! - edge.cumulative[index]!;
      best = {
        offset: edge.cumulative[index]! + fraction * segmentLength,
        distance,
        point: {
          latitude: start.latitude + fraction * (end.latitude - start.latitude),
          longitude: start.longitude + fraction * (end.longitude - start.longitude),
        },
      };
    }
  }
  return best;
}

function pointAt(edge: DecodedEdge, offset: number): PolylineCoordinate {
  const clamped = Math.min(edge.length, Math.max(0, offset));
  let index = 0;
  while (index < edge.cumulative.length - 2 && edge.cumulative[index + 1]! < clamped) index += 1;
  const start = edge.coordinates[index]!;
  const end = edge.coordinates[index + 1]!;
  const segmentLength = edge.cumulative[index + 1]! - edge.cumulative[index]!;
  const fraction = segmentLength === 0 ? 0 : (clamped - edge.cumulative[index]!) / segmentLength;
  return {
    latitude: start.latitude + fraction * (end.latitude - start.latitude),
    longitude: start.longitude + fraction * (end.longitude - start.longitude),
  };
}

/** The edge between two offsets, in the direction of travel. */
function slice(edge: DecodedEdge, from: number, to: number): PolylineCoordinate[] {
  const low = Math.min(from, to);
  const high = Math.max(from, to);
  const result = [pointAt(edge, low)];
  for (let index = 0; index < edge.coordinates.length; index += 1) {
    const offset = edge.cumulative[index]!;
    if (offset > low && offset < high) result.push(edge.coordinates[index]!);
  }
  result.push(pointAt(edge, high));
  return from <= to ? result : result.reverse();
}

function appendPath(path: PolylineCoordinate[], addition: readonly PolylineCoordinate[]): void {
  for (const coordinate of addition) {
    const last = path.at(-1);
    if (last === undefined
      || Math.abs(last.latitude - coordinate.latitude) > 1e-6
      || Math.abs(last.longitude - coordinate.longitude) > 1e-6) {
      path.push(coordinate);
    }
  }
}

/**
 * Route lines for Amtrak trains, found by walking a train's stops along the federal route
 * network: every stop must lie on one route's lines, and consecutive stops must be joined by a
 * plausible path along them. Anything else returns no geometry, so the map keeps its
 * station-to-station line.
 */
export class NTADAmtrakRouteGeometrySource implements NorthAmericanIntercityRouteGeometrySource {
  private readonly decoded = new Map<number, DecodedEdge | null>();

  constructor(private readonly data: NTADAmtrakRouteNetworkData) {}

  async geometryFor(
    operatorName: string,
    _trainNumber: string,
    stops: readonly NorthAmericanIntercityRouteGeometryStop[],
  ): Promise<RouteGeometrySnapshot | null> {
    if (normalizedNorthAmericanIntercityOperator(operatorName) !== "amtrak") return null;
    const located = stops.flatMap((stop): PolylineCoordinate[] => (
      stop.latitude === null || stop.longitude === null
        ? []
        : [{ latitude: stop.latitude, longitude: stop.longitude }]
    ));
    // A stop without coordinates could hide a branch; only a fully located train is matched.
    if (located.length < 2 || located.length !== stops.length) return null;

    let best: { path: PolylineCoordinate[]; cost: number } | null = null;
    for (const route of this.data.routes) {
      if (!withinBounds(route, located)) continue;
      const candidate = this.pathAlong(route, located);
      if (candidate !== null && (best === null || candidate.cost < best.cost)) best = candidate;
    }
    if (best === null || best.path.length < 2 || best.path.length > maximumPointCount) return null;
    return {
      source: ntadAmtrakRoutesSourceLabel,
      segments: [{ encodedPolyline: encodePolyline5(best.path), precision: 5, pointCount: best.path.length }],
    };
  }

  private edge(index: number): DecodedEdge | null {
    const cached = this.decoded.get(index);
    if (cached !== undefined) return cached;
    const stored = this.data.edges[index];
    const coordinates = stored === undefined ? null : decodePolyline5(stored[0], stored[1]);
    let decoded: DecodedEdge | null = null;
    if (coordinates !== null && coordinates.length >= 2) {
      const cumulative = [0];
      for (let point = 1; point < coordinates.length; point += 1) {
        cumulative.push(cumulative[point - 1]! + distanceMeters(coordinates[point - 1]!, coordinates[point]!));
      }
      decoded = { coordinates, cumulative, length: cumulative.at(-1)! };
    }
    this.decoded.set(index, decoded);
    return decoded;
  }

  private pathAlong(
    route: NTADRoute,
    stops: readonly PolylineCoordinate[],
  ): { path: PolylineCoordinate[]; cost: number } | null {
    const edges = route.edges.map((use) => this.edge(use[0]));
    if (edges.some((edge) => edge === null)) return null;
    const decoded = edges as DecodedEdge[];

    const snaps: Snap[] = [];
    let cost = 0;
    for (const stop of stops) {
      let nearest: Snap | null = null;
      for (let use = 0; use < decoded.length; use += 1) {
        const candidate = nearestOnEdge(decoded[use]!, stop);
        if (nearest === null || candidate.distance < nearest.distance) nearest = { use, ...candidate };
      }
      if (nearest === null || nearest.distance > stopSnapLimitMeters) return null;
      snaps.push(nearest);
      cost += nearest.distance;
    }

    const path: PolylineCoordinate[] = [];
    for (let index = 0; index < snaps.length - 1; index += 1) {
      const direct = distanceMeters(stops[index]!, stops[index + 1]!);
      const leg = this.leg(route, decoded, snaps[index]!, snaps[index + 1]!);
      // A path far longer than the straight line means the network sent the train the wrong
      // way round; a mountain line rarely exceeds one and a half times the straight distance.
      if (leg === null || leg.length > Math.max(direct * 2.2, direct + 10_000)) return null;
      appendPath(path, leg.coordinates);
    }
    return path.length < 2 ? null : { path, cost: cost / snaps.length };
  }

  /** The shortest way along the route's lines from one snapped stop to the next. */
  private leg(
    route: NTADRoute,
    decoded: readonly DecodedEdge[],
    from: Snap,
    to: Snap,
  ): { coordinates: PolylineCoordinate[]; length: number } | null {
    let best: { coordinates: PolylineCoordinate[]; length: number } | null = null;
    if (from.use === to.use) {
      best = { coordinates: slice(decoded[from.use]!, from.offset, to.offset), length: Math.abs(to.offset - from.offset) };
    }

    const nodeCount = route.edges.reduce((count, use) => Math.max(count, use[1] + 1, use[2] + 1), 0);
    const distance = new Array<number>(nodeCount).fill(Number.POSITIVE_INFINITY);
    const previous = new Array<{ node: number; use: number } | null>(nodeCount).fill(null);
    const settled = new Array<boolean>(nodeCount).fill(false);
    const fromEdge = decoded[from.use]!;
    const fromUse = route.edges[from.use]!;
    distance[fromUse[1]] = Math.min(distance[fromUse[1]]!, from.offset);
    distance[fromUse[2]] = Math.min(distance[fromUse[2]]!, fromEdge.length - from.offset);

    for (;;) {
      let current = -1;
      for (let node = 0; node < nodeCount; node += 1) {
        if (!settled[node] && distance[node]! < Number.POSITIVE_INFINITY
          && (current === -1 || distance[node]! < distance[current]!)) current = node;
      }
      if (current === -1) break;
      settled[current] = true;
      for (let use = 0; use < route.edges.length; use += 1) {
        const [, start, end] = route.edges[use]!;
        const neighbour = start === current ? end : end === current ? start : -1;
        if (neighbour === -1 || neighbour === current) continue;
        const through = distance[current]! + decoded[use]!.length;
        if (through < distance[neighbour]!) {
          distance[neighbour] = through;
          previous[neighbour] = { node: current, use };
        }
      }
    }

    const toEdge = decoded[to.use]!;
    const toUse = route.edges[to.use]!;
    const viaStart = distance[toUse[1]]! + to.offset;
    const viaEnd = distance[toUse[2]]! + (toEdge.length - to.offset);
    const arrival = viaStart <= viaEnd ? { node: toUse[1], length: viaStart } : { node: toUse[2], length: viaEnd };
    if (arrival.length < Number.POSITIVE_INFINITY && (best === null || arrival.length < best.length)) {
      // Walk back from the arrival node to the node the train left its first edge by.
      const hops: Array<{ use: number; from: number; to: number }> = [];
      let node = arrival.node;
      while (previous[node] !== null) {
        const step = previous[node]!;
        hops.push({ use: step.use, from: step.node, to: node });
        node = step.node;
      }
      hops.reverse();
      const coordinates: PolylineCoordinate[] = [];
      appendPath(coordinates, slice(fromEdge, from.offset, node === fromUse[1] ? 0 : fromEdge.length));
      for (const hop of hops) {
        const edge = decoded[hop.use]!;
        const forward = route.edges[hop.use]![1] === hop.from;
        appendPath(coordinates, forward ? edge.coordinates : [...edge.coordinates].reverse());
      }
      appendPath(coordinates, slice(toEdge, arrival.node === toUse[1] ? 0 : toEdge.length, to.offset));
      best = { coordinates, length: arrival.length };
    }
    return best;
  }
}

function withinBounds(route: NTADRoute, stops: readonly PolylineCoordinate[]): boolean {
  const [minLatitude, minLongitude, maxLatitude, maxLongitude] = route.bounds;
  return stops.every((stop) => stop.latitude >= minLatitude - boundsMarginDegrees
    && stop.latitude <= maxLatitude + boundsMarginDegrees
    && stop.longitude >= minLongitude - boundsMarginDegrees
    && stop.longitude <= maxLongitude + boundsMarginDegrees);
}

/** Tries each source in turn; the first that knows the train's route answers. */
export class FirstMatchingRouteGeometrySource implements NorthAmericanIntercityRouteGeometrySource {
  constructor(private readonly sources: readonly NorthAmericanIntercityRouteGeometrySource[]) {}

  async geometryFor(
    operatorName: string,
    trainNumber: string,
    stops: readonly NorthAmericanIntercityRouteGeometryStop[],
  ): Promise<RouteGeometrySnapshot | null> {
    for (const source of this.sources) {
      const geometry = await source.geometryFor(operatorName, trainNumber, stops).catch(() => null);
      if (geometry !== null) return geometry;
    }
    return null;
  }
}
