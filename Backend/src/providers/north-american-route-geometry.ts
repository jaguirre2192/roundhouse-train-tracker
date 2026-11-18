import {
  NorthAmericanIntercityGTFSGeometryCatalog,
  type NorthAmericanIntercityRouteGeometrySource,
} from "./north-american-intercity-gtfs-geometry.js";
import type { NorthAmericanIntercityOperator } from "./north-american-intercity-gtfs-model.js";
import { FirstMatchingRouteGeometrySource, NTADAmtrakRouteGeometrySource } from "./ntad-amtrak-route-geometry.js";
import { ntadAmtrakRouteNetwork } from "./ntad-amtrak-routes.generated.js";

/**
 * The route lines the Amtraker adapter may draw. Operators' own GTFS shapes come first where a
 * distribution approval allows them; Amtrak trains without one fall to the federal route network
 * when that is switched on. With neither, the map keeps its station-to-station line.
 */
export function northAmericanRouteGeometrySource(options: {
  gtfsOperators: readonly NorthAmericanIntercityOperator[];
  amtrakNTADRoutes: boolean;
}): NorthAmericanIntercityRouteGeometrySource | null {
  const sources: NorthAmericanIntercityRouteGeometrySource[] = [];
  if (options.gtfsOperators.length > 0) {
    sources.push(new NorthAmericanIntercityGTFSGeometryCatalog({ enabledOperators: options.gtfsOperators }));
  }
  if (options.amtrakNTADRoutes) sources.push(new NTADAmtrakRouteGeometrySource(ntadAmtrakRouteNetwork));
  if (sources.length === 0) return null;
  return sources.length === 1 ? sources[0]! : new FirstMatchingRouteGeometrySource(sources);
}
