/**
 * Compiles the U.S. Bureau of Transportation Statistics' "Amtrak Routes" layer (National
 * Transportation Atlas Database) into the route network the Amtraker adapter draws from.
 *
 *   npm run generate:ntad-amtrak-routes                      download and write the module
 *   npm run generate:ntad-amtrak-routes -- --input file.geojson   compile a saved download
 *   npm run generate:ntad-amtrak-routes -- --report          print statistics only
 *
 * The layer is a work of the United States government. The compiler refuses to run if the
 * layer's own copyright statement stops saying so.
 */
import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { encodePolyline5, type PolylineCoordinate } from "../src/providers/encoded-polyline.js";
import type { NTADAmtrakRouteNetworkData, NTADRouteEdgeUse } from "../src/providers/ntad-amtrak-routes-model.js";

const service = "https://services.arcgis.com/xOi1kZaI0eWDREZv/arcgis/rest/services/NTAD_Amtrak_Routes/FeatureServer";
const datasetPage = "https://geodata.bts.gov/datasets/usdot::amtrak-routes/about";
const requiredCopyrightStatement = "not protected by any U.S. copyrights";
const defaultOutput = fileURLToPath(new URL("../src/providers/ntad-amtrak-routes.generated.ts", import.meta.url));

/** Ends closer than this are the same junction; an end this close to another line joins it. */
const joinMeters = 300;
/** Larger breaks between pieces of one route are left open rather than drawn across. */
const bridgeMeters = 2_000;
/** Douglas-Peucker tolerance: invisible on a route map, a fifteenth of the source's points. */
const simplifyMeters = 20;

type Point = PolylineCoordinate;
interface SourceRoute { name: string; parts: Point[][] }

function distanceMeters(left: Point, right: Point): number {
  const radians = Math.PI / 180;
  const latitudeDelta = (right.latitude - left.latitude) * radians;
  const longitudeDelta = (right.longitude - left.longitude) * radians;
  const haversine = Math.sin(latitudeDelta / 2) ** 2
    + Math.cos(left.latitude * radians) * Math.cos(right.latitude * radians) * Math.sin(longitudeDelta / 2) ** 2;
  return 2 * 6_371_000 * Math.asin(Math.min(1, Math.sqrt(haversine)));
}

function lengthMeters(points: readonly Point[]): number {
  let total = 0;
  for (let index = 1; index < points.length; index += 1) total += distanceMeters(points[index - 1]!, points[index]!);
  return total;
}

function simplify(points: readonly Point[], tolerance: number): Point[] {
  if (points.length < 3) return [...points];
  const metersPerLongitude = 111_320 * Math.cos(points[0]!.latitude * Math.PI / 180);
  const flat = points.map((point) => [point.longitude * metersPerLongitude, point.latitude * 110_540] as const);
  const keep = new Array<boolean>(points.length).fill(false);
  keep[0] = true;
  keep[points.length - 1] = true;
  const stack: Array<[number, number]> = [[0, points.length - 1]];
  while (stack.length > 0) {
    const [start, end] = stack.pop()!;
    if (end <= start + 1) continue;
    const [startX, startY] = flat[start]!;
    const [endX, endY] = flat[end]!;
    const deltaX = endX - startX;
    const deltaY = endY - startY;
    const lengthSquared = deltaX * deltaX + deltaY * deltaY;
    let furthest = -1;
    let furthestDistance = -1;
    for (let index = start + 1; index < end; index += 1) {
      const [x, y] = flat[index]!;
      const fraction = lengthSquared === 0 ? 0 : Math.min(1, Math.max(0, ((x - startX) * deltaX + (y - startY) * deltaY) / lengthSquared));
      const distance = Math.hypot(x - (startX + fraction * deltaX), y - (startY + fraction * deltaY));
      if (distance > furthestDistance) {
        furthestDistance = distance;
        furthest = index;
      }
    }
    if (furthestDistance > tolerance) {
      keep[furthest] = true;
      stack.push([start, furthest], [furthest, end]);
    }
  }
  return points.filter((_, index) => keep[index]);
}

class Groups {
  private readonly parent: number[];
  constructor(count: number) { this.parent = Array.from({ length: count }, (_, index) => index); }
  find(index: number): number {
    let root = index;
    while (this.parent[root] !== root) root = this.parent[root]!;
    while (this.parent[index] !== root) [index, this.parent[index]] = [this.parent[index]!, root];
    return root;
  }
  join(left: number, right: number): void { this.parent[this.find(left)] = this.find(right); }
}

interface CompiledRoute {
  name: string;
  edges: Array<{ points: Point[]; startNode: number; endNode: number }>;
  bridges: number[];
  openBreaks: number;
}

function compileRoute(route: SourceRoute): CompiledRoute {
  // 1. Where the end of one piece meets the middle of another, cut the other piece there, so
  //    every junction is an end.
  let parts = route.parts.filter((part) => part.length >= 2);
  const cuts = parts.map(() => new Set<number>());
  parts.forEach((part, index) => {
    for (const end of [part[0]!, part.at(-1)!]) {
      parts.forEach((other, otherIndex) => {
        if (otherIndex === index) return;
        if (distanceMeters(end, other[0]!) <= joinMeters || distanceMeters(end, other.at(-1)!) <= joinMeters) return;
        let nearest = -1;
        let nearestDistance = Number.POSITIVE_INFINITY;
        for (let vertex = 1; vertex < other.length - 1; vertex += 1) {
          const distance = distanceMeters(end, other[vertex]!);
          if (distance < nearestDistance) {
            nearestDistance = distance;
            nearest = vertex;
          }
        }
        if (nearest !== -1 && nearestDistance <= joinMeters) cuts[otherIndex]!.add(nearest);
      });
    }
  });
  parts = parts.flatMap((part, index) => {
    const indices = [...cuts[index]!].sort((left, right) => left - right);
    const pieces: Point[][] = [];
    let start = 0;
    for (const cut of indices) {
      pieces.push(part.slice(start, cut + 1));
      start = cut;
    }
    pieces.push(part.slice(start));
    return pieces.filter((piece) => piece.length >= 2 && lengthMeters(piece) >= 1);
  });

  // 2. Ends within reach of each other are one node.
  const ends = parts.flatMap((part) => [part[0]!, part.at(-1)!]);
  const nodes = new Groups(ends.length);
  for (let left = 0; left < ends.length; left += 1) {
    for (let right = left + 1; right < ends.length; right += 1) {
      if (distanceMeters(ends[left]!, ends[right]!) <= joinMeters) nodes.join(left, right);
    }
  }

  // 3. Short breaks in the source are closed with a straight link; long ones stay open.
  const bridges: number[] = [];
  const bridgeEdges: Array<{ points: Point[]; left: number; right: number }> = [];
  const connected = new Groups(ends.length);
  for (let end = 0; end < ends.length; end += 1) connected.join(end, nodes.find(end));
  parts.forEach((_, index) => connected.join(index * 2, index * 2 + 1));
  for (;;) {
    let closest: { left: number; right: number; distance: number } | null = null;
    for (let left = 0; left < ends.length; left += 1) {
      for (let right = left + 1; right < ends.length; right += 1) {
        if (connected.find(left) === connected.find(right)) continue;
        const distance = distanceMeters(ends[left]!, ends[right]!);
        if (closest === null || distance < closest.distance) closest = { left, right, distance };
      }
    }
    if (closest === null || closest.distance > bridgeMeters) break;
    bridges.push(Math.round(closest.distance));
    bridgeEdges.push({ points: [ends[closest.left]!, ends[closest.right]!], left: closest.left, right: closest.right });
    connected.join(closest.left, closest.right);
  }
  const openBreaks = new Set(ends.map((_, index) => connected.find(index))).size - 1;

  const nodeIDs = new Map<number, number>();
  const nodeID = (end: number): number => {
    const root = nodes.find(end);
    if (!nodeIDs.has(root)) nodeIDs.set(root, nodeIDs.size);
    return nodeIDs.get(root)!;
  };
  const edges = [
    ...parts.map((part, index) => ({ points: simplify(part, simplifyMeters), startNode: nodeID(index * 2), endNode: nodeID(index * 2 + 1) })),
    ...bridgeEdges.map((bridge) => ({ points: bridge.points, startNode: nodeID(bridge.left), endNode: nodeID(bridge.right) })),
  ];
  return { name: route.name, edges, bridges, openBreaks };
}

async function getJSON(url: string): Promise<any> {
  const response = await fetch(url, { headers: { "user-agent": "route-network-compiler" } });
  if (!response.ok) throw new Error(`${url} returned ${response.status}`);
  return response.json();
}

function routesFromGeoJSON(collection: any): SourceRoute[] {
  return (collection.features as any[]).map((feature) => {
    const geometry = feature.geometry;
    const lines: number[][][] = geometry.type === "MultiLineString" ? geometry.coordinates : [geometry.coordinates];
    return {
      name: String(feature.properties.name).trim(),
      parts: lines.map((line) => line.map(([longitude, latitude]) => ({ latitude: latitude!, longitude: longitude! }))),
    };
  }).sort((left, right) => left.name.localeCompare(right.name));
}

async function download(): Promise<{ routes: SourceRoute[]; modified: string }> {
  const layer = await getJSON(`${service}/0?f=json`);
  if (typeof layer.copyrightText !== "string" || !layer.copyrightText.includes(requiredCopyrightStatement)) {
    throw new Error("The Amtrak Routes layer no longer states that it is free of U.S. copyright; review its terms before compiling.");
  }
  const item = await getJSON(`https://www.arcgis.com/sharing/rest/content/items/${layer.serviceItemId}?f=json`);
  const expected = (await getJSON(`${service}/0/query?where=1%3D1&returnCountOnly=true&f=json`)).count as number;
  const features: any[] = [];
  const pageSize = 7;
  for (let offset = 0; features.length < expected; offset += pageSize) {
    const page = await getJSON(
      `${service}/0/query?where=1%3D1&outFields=name&outSR=4326&geometryPrecision=5&orderByFields=OBJECTID`
        + `&resultOffset=${offset}&resultRecordCount=${pageSize}&f=geojson`,
    );
    if (!Array.isArray(page.features) || page.features.length === 0) break;
    features.push(...page.features);
  }
  if (features.length !== expected) throw new Error(`Downloaded ${features.length} of ${expected} routes`);
  return {
    routes: routesFromGeoJSON({ features }),
    modified: new Date(item.modified).toISOString().slice(0, 10),
  };
}

function option(name: string): string | null {
  const index = process.argv.indexOf(name);
  return index === -1 ? null : process.argv[index + 1] ?? null;
}

async function main(): Promise<void> {
  const input = option("--input");
  const source = input === null
    ? await download()
    : { routes: routesFromGeoJSON(JSON.parse(await readFile(input, "utf8"))), modified: option("--modified") ?? "unknown" };
  const sourceDigest = createHash("sha256").update(JSON.stringify(source.routes)).digest("hex");

  const edgeIndex = new Map<string, number>();
  const edges: Array<[string, number]> = [];
  const routes: NTADAmtrakRouteNetworkData["routes"][number][] = [];
  const report: string[] = [];
  for (const sourceRoute of source.routes) {
    const compiled = compileRoute(sourceRoute);
    const uses: NTADRouteEdgeUse[] = [];
    let minLatitude = 90, minLongitude = 180, maxLatitude = -90, maxLongitude = -180;
    for (const edge of compiled.edges) {
      // One canonical direction, so track shared by several routes is stored once.
      const first = edge.points[0]!;
      const last = edge.points.at(-1)!;
      const reversed = first.latitude > last.latitude || (first.latitude === last.latitude && first.longitude > last.longitude);
      const points = reversed ? [...edge.points].reverse() : edge.points;
      const encoded = encodePolyline5(points);
      if (!edgeIndex.has(encoded)) {
        edgeIndex.set(encoded, edges.length);
        edges.push([encoded, points.length]);
      }
      uses.push([edgeIndex.get(encoded)!, reversed ? edge.endNode : edge.startNode, reversed ? edge.startNode : edge.endNode]);
      for (const point of points) {
        minLatitude = Math.min(minLatitude, point.latitude);
        maxLatitude = Math.max(maxLatitude, point.latitude);
        minLongitude = Math.min(minLongitude, point.longitude);
        maxLongitude = Math.max(maxLongitude, point.longitude);
      }
    }
    const round = (value: number): number => Math.round(value * 1e4) / 1e4;
    routes.push({ name: compiled.name, bounds: [round(minLatitude), round(minLongitude), round(maxLatitude), round(maxLongitude)], edges: uses });
    report.push(`${compiled.name}: ${compiled.edges.length} edges, ${compiled.bridges.length} short breaks closed`
      + `${compiled.bridges.length > 0 ? ` (${compiled.bridges.join(", ")} m)` : ""}, ${compiled.openBreaks} left open`);
  }

  const points = edges.reduce((total, edge) => total + edge[1], 0);
  console.log(report.join("\n"));
  console.log(`\n${routes.length} routes, ${edges.length} edges, ${points} points, source ${source.modified}, sha256 ${sourceDigest}`);
  if (process.argv.includes("--report")) return;

  const data: NTADAmtrakRouteNetworkData = { edges, routes };
  const module = `// Generated by scripts/ntad-amtrak-routes-compiler.ts. Do not edit.
//
// Source: "Amtrak Routes", National Transportation Atlas Database, U.S. Department of
// Transportation, Bureau of Transportation Statistics. A work of the United States government
// under 17 U.S.C. § 101, not protected by U.S. copyright and available for unrestricted public
// use. Acknowledgment: Federal Railroad Administration, Amtrak and BTS.
import type { NTADAmtrakRouteNetworkData } from "./ntad-amtrak-routes-model.js";

export const ntadAmtrakRoutesDatasetPage = ${JSON.stringify(datasetPage)};
export const ntadAmtrakRoutesService = ${JSON.stringify(service)};
/** When BTS last modified the layer. */
export const ntadAmtrakRoutesSourceModified = ${JSON.stringify(source.modified)};
/** SHA-256 of the downloaded route names and coordinates, at five decimal places. */
export const ntadAmtrakRoutesSourceSHA256 = ${JSON.stringify(sourceDigest)};

export const ntadAmtrakRouteNetwork: NTADAmtrakRouteNetworkData = ${JSON.stringify(data)};
`;
  const output = option("--output") ?? defaultOutput;
  await writeFile(output, module);
  console.log(`Wrote ${output} (${Math.round(module.length / 1024)} KB)`);
}

await main();
