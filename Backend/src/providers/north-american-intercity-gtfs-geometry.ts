import type { RouteGeometrySnapshot } from "../domain/snapshot.js";
import {
  northAmericanIntercityGTFSDistributionApprovalReferences,
  northAmericanIntercityGTFSFeedVersion,
  northAmericanIntercityGTFSMatches,
  northAmericanIntercityGTFSPartialMatches,
  northAmericanIntercityGTFSShapes,
} from "./north-american-intercity-gtfs-shapes.approved.js";
import {
  northAmericanIntercityGTFSMatchKey,
  northAmericanIntercityGTFSPartialMatchKey,
  normalizedNorthAmericanIntercityOperator,
  type NorthAmericanIntercityGTFSGeometryData,
  type NorthAmericanIntercityOperator,
} from "./north-american-intercity-gtfs-model.js";
import {
  decodePolyline5,
  encodePolyline5,
  type PolylineCoordinate,
} from "./encoded-polyline.js";

export type { NorthAmericanIntercityGTFSGeometryData } from "./north-american-intercity-gtfs-model.js";

export interface NorthAmericanIntercityRouteGeometryStop {
  code: string;
  latitude: number | null;
  longitude: number | null;
}

export interface NorthAmericanIntercityRouteGeometrySource {
  geometryFor(
    operatorName: string,
    trainNumber: string,
    stops: readonly NorthAmericanIntercityRouteGeometryStop[],
  ): Promise<RouteGeometrySnapshot | null>;
}

const approvedData: NorthAmericanIntercityGTFSGeometryData = {
  feedVersion: northAmericanIntercityGTFSFeedVersion,
  matches: northAmericanIntercityGTFSMatches,
  partialMatches: northAmericanIntercityGTFSPartialMatches,
  shapes: northAmericanIntercityGTFSShapes,
};

export interface NorthAmericanIntercityGTFSGeometryCatalogOptions {
  data?: NorthAmericanIntercityGTFSGeometryData;
  enabledOperators?: readonly NorthAmericanIntercityOperator[];
}

export class NorthAmericanIntercityGTFSGeometryCatalog implements NorthAmericanIntercityRouteGeometrySource {
  private readonly data: NorthAmericanIntercityGTFSGeometryData;
  private readonly enabledOperators: ReadonlySet<NorthAmericanIntercityOperator>;

  constructor(options: NorthAmericanIntercityGTFSGeometryCatalogOptions = {}) {
    const enabledOperators = options.enabledOperators ?? [];
    if (options.data === undefined) {
      const unapproved = enabledOperators.filter(
        (operator) => northAmericanIntercityGTFSDistributionApprovalReferences[operator] === undefined,
      );
      if (unapproved.length > 0) {
        throw new Error(`North American intercity GTFS geometry has no distribution approval for: ${unapproved.join(", ")}`);
      }
    }
    this.data = options.data ?? approvedData;
    this.enabledOperators = new Set(enabledOperators);
  }

  async geometryFor(
    operatorName: string,
    trainNumber: string,
    stops: readonly NorthAmericanIntercityRouteGeometryStop[],
  ): Promise<RouteGeometrySnapshot | null> {
    const operator = normalizedNorthAmericanIntercityOperator(operatorName);
    if (operator === null || !this.enabledOperators.has(operator)) return null;
    const key = northAmericanIntercityGTFSMatchKey(operator, trainNumber, stops.map((stop) => stop.code));
    if (key === null) return null;
    const exactShapeID = this.data.matches[key];
    if (exactShapeID !== undefined) return this.geometry(exactShapeID);

    const partialKey = northAmericanIntercityGTFSPartialMatchKey(operator, trainNumber);
    if (partialKey === null) return null;
    const shapeID = this.data.partialMatches[partialKey];
    if (shapeID === undefined) return null;
    const shape = this.data.shapes[shapeID];
    if (shape === undefined) return null;
    const [encodedPolyline, pointCount, source] = shape;
    if (encodedPolyline.length === 0 || pointCount < 2 || pointCount > 100_000) return null;
    const clipped = clippedPolyline(
      encodedPolyline,
      pointCount,
      stops,
    );
    if (clipped === null) return null;
    return {
      source,
      segments: [{
        encodedPolyline: clipped.encodedPolyline,
        precision: 5,
        pointCount: clipped.pointCount,
      }],
    };
  }

  private geometry(shapeID: string): RouteGeometrySnapshot | null {
    const shape = this.data.shapes[shapeID];
    if (shape === undefined) return null;
    const [encodedPolyline, pointCount, source] = shape;
    if (encodedPolyline.length === 0 || pointCount < 2 || pointCount > 100_000) return null;
    return {
      source,
      segments: [{ encodedPolyline, precision: 5, pointCount }],
    };
  }
}

function distanceMeters(left: PolylineCoordinate, right: PolylineCoordinate): number {
  const radians = Math.PI / 180;
  const latitudeDelta = (right.latitude - left.latitude) * radians;
  const longitudeDelta = (right.longitude - left.longitude) * radians;
  const leftLatitude = left.latitude * radians;
  const rightLatitude = right.latitude * radians;
  const haversine = Math.sin(latitudeDelta / 2) ** 2
    + Math.cos(leftLatitude) * Math.cos(rightLatitude) * Math.sin(longitudeDelta / 2) ** 2;
  return 2 * 6_371_000 * Math.asin(Math.min(1, Math.sqrt(haversine)));
}

interface ShapeMatch {
  index: number;
  cost: number;
  previous: number;
}

function shapeCandidates(
  coordinates: readonly PolylineCoordinate[],
  target: PolylineCoordinate,
): ShapeMatch[] {
  const matches: ShapeMatch[] = [];
  for (let index = 0; index < coordinates.length; index += 1) {
    const coordinate = coordinates[index]!;
    const distance = distanceMeters(coordinate, target);
    if (distance <= 10_000) matches.push({ index, cost: distance, previous: -1 });
  }
  return matches;
}

function matchedShapeIndices(
  coordinates: readonly PolylineCoordinate[],
  stops: readonly PolylineCoordinate[],
): number[] | null {
  const layers: ShapeMatch[][] = [];
  let previous = shapeCandidates(coordinates, stops[0]!);
  if (previous.length === 0) return null;
  layers.push(previous);

  for (const stop of stops.slice(1)) {
    const candidates = shapeCandidates(coordinates, stop);
    const reachable: ShapeMatch[] = [];
    let previousCursor = 0;
    let bestPrevious = -1;
    let bestCost = Number.POSITIVE_INFINITY;
    for (const candidate of candidates) {
      while (previousCursor < previous.length
        && previous[previousCursor]!.index < candidate.index) {
        const prior = previous[previousCursor]!;
        if (prior.cost < bestCost) {
          bestCost = prior.cost;
          bestPrevious = previousCursor;
        }
        previousCursor += 1;
      }
      if (bestPrevious >= 0) {
        reachable.push({
          index: candidate.index,
          cost: bestCost + candidate.cost,
          previous: bestPrevious,
        });
      }
    }
    if (reachable.length === 0) return null;
    previous = reachable;
    layers.push(reachable);
  }

  let selected = previous.reduce(
    (best, candidate, index) => candidate.cost < previous[best]!.cost ? index : best,
    0,
  );
  const indices = new Array<number>(layers.length);
  for (let layer = layers.length - 1; layer >= 0; layer -= 1) {
    const match = layers[layer]![selected]!;
    indices[layer] = match.index;
    selected = match.previous;
  }
  return indices;
}

function clippedPolyline(
  encodedPolyline: string,
  pointCount: number,
  stops: readonly NorthAmericanIntercityRouteGeometryStop[],
): { encodedPolyline: string; pointCount: number } | null {
  const coordinates = decodePolyline5(encodedPolyline, pointCount);
  if (coordinates === null) return null;
  const locatedStops = stops.flatMap((stop): PolylineCoordinate[] => (
    stop.latitude === null || stop.longitude === null
      ? []
      : [{ latitude: stop.latitude, longitude: stop.longitude }]
  ));
  if (locatedStops.length < 2) return null;
  const shapeIndices = matchedShapeIndices(coordinates, locatedStops);
  if (shapeIndices === null) return null;
  const clipped = coordinates.slice(shapeIndices[0], shapeIndices.at(-1)! + 1);
  return clipped.length < 2
    ? null
    : { encodedPolyline: encodePolyline5(clipped), pointCount: clipped.length };
}
