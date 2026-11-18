/**
 * Amtrak route lines from the U.S. Bureau of Transportation Statistics' National Transportation
 * Atlas Database ("Amtrak Routes"), compiled into a small network per route. NTAD is a work of
 * the United States government and is not protected by U.S. copyright, so unlike the operators'
 * GTFS archives it needs no distribution approval.
 */

/** One piece of track between two junctions or ends of a route, as a precision-5 polyline. */
export type NTADRouteEdge = readonly [encodedPolyline: string, pointCount: number];

/** An edge as one route uses it: the edge, and that route's nodes at its start and its end. */
export type NTADRouteEdgeUse = readonly [edge: number, startNode: number, endNode: number];

export interface NTADRoute {
  name: string;
  /** minLatitude, minLongitude, maxLatitude, maxLongitude. */
  bounds: readonly [number, number, number, number];
  edges: readonly NTADRouteEdgeUse[];
}

export interface NTADAmtrakRouteNetworkData {
  edges: readonly NTADRouteEdge[];
  routes: readonly NTADRoute[];
}

export const ntadAmtrakRoutesSourceLabel = "Amtrak Routes, U.S. DOT BTS National Transportation Atlas Database";
