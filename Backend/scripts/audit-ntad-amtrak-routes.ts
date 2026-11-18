/**
 * Checks the compiled federal route network against the trains Amtraker lists right now: how
 * many Amtrak trains get a route line, which do not, and whether any line is implausibly long
 * for its stops. Read-only; it changes nothing.
 */
import { decodePolyline5 } from "../src/providers/encoded-polyline.js";
import { normalizedNorthAmericanIntercityOperator } from "../src/providers/north-american-intercity-gtfs-model.js";
import { NTADAmtrakRouteGeometrySource } from "../src/providers/ntad-amtrak-route-geometry.js";
import { ntadAmtrakRouteNetwork, ntadAmtrakRoutesSourceModified } from "../src/providers/ntad-amtrak-routes.generated.js";

interface Station { code: string; lat?: number | null; lon?: number | null }
interface Train { trainID: string; trainNum: string; routeName?: string; provider?: string | null; stations: { code: string }[] }

async function fetchJSON<T>(path: string): Promise<T> {
  const response = await fetch(`https://api.amtraker.com/v3/${path}`, {
    headers: { accept: "application/json", "user-agent": "route-geometry-audit" },
    signal: AbortSignal.timeout(20_000),
  });
  if (!response.ok) throw new Error(`Amtraker ${path} returned ${response.status}`);
  return response.json() as Promise<T>;
}

function meters(a: { latitude: number; longitude: number }, b: { latitude: number; longitude: number }): number {
  const r = Math.PI / 180;
  const h = Math.sin((b.latitude - a.latitude) * r / 2) ** 2
    + Math.cos(a.latitude * r) * Math.cos(b.latitude * r) * Math.sin((b.longitude - a.longitude) * r / 2) ** 2;
  return 2 * 6_371_000 * Math.asin(Math.min(1, Math.sqrt(h)));
}

const [stations, trains] = await Promise.all([
  fetchJSON<Record<string, Station>>("stations"),
  fetchJSON<Record<string, Train[]>>("trains"),
]);
const source = new NTADAmtrakRouteGeometrySource(ntadAmtrakRouteNetwork);
const amtrak = Object.values(trains).flat()
  .filter((train) => normalizedNorthAmericanIntercityOperator(train.provider ?? "Amtrak") === "amtrak");

let matched = 0;
const unmatched = new Map<string, string[]>();
const suspicious: string[] = [];
const ratios: number[] = [];
for (const train of amtrak) {
  const stops = train.stations.map((stop) => ({
    code: stop.code,
    latitude: stations[stop.code]?.lat ?? null,
    longitude: stations[stop.code]?.lon ?? null,
  }));
  const geometry = await source.geometryFor("Amtrak", train.trainNum, stops);
  const route = train.routeName ?? "unknown route";
  if (geometry === null) {
    const missing = stops.filter((stop) => stop.latitude === null).map((stop) => stop.code);
    unmatched.set(route, [...(unmatched.get(route) ?? []), `${train.trainNum}${missing.length > 0 ? ` (no coordinates: ${missing.join(",")})` : ""}`]);
    continue;
  }
  matched += 1;
  const segment = geometry.segments[0]!;
  const line = decodePolyline5(segment.encodedPolyline, segment.pointCount)!;
  let drawn = 0;
  for (let index = 1; index < line.length; index += 1) drawn += meters(line[index - 1]!, line[index]!);
  let straight = 0;
  for (let index = 1; index < stops.length; index += 1) {
    straight += meters(
      { latitude: stops[index - 1]!.latitude!, longitude: stops[index - 1]!.longitude! },
      { latitude: stops[index]!.latitude!, longitude: stops[index]!.longitude! },
    );
  }
  const ratio = straight === 0 ? 1 : drawn / straight;
  ratios.push(ratio);
  if (ratio > 1.5 || ratio < 0.98) suspicious.push(`${route} ${train.trainNum}: drawn ${Math.round(drawn / 1000)} km for ${Math.round(straight / 1000)} km between stops`);
}

ratios.sort((left, right) => left - right);
console.log(`Federal route layer modified ${ntadAmtrakRoutesSourceModified}.`);
console.log(`Amtrak trains listed: ${amtrak.length}. With a route line: ${matched}. Without: ${amtrak.length - matched}.`);
if (ratios.length > 0) {
  console.log(`Drawn length over straight stop-to-stop length: median ${ratios[Math.floor(ratios.length / 2)]!.toFixed(3)}, largest ${ratios.at(-1)!.toFixed(3)}.`);
}
for (const [route, numbers] of [...unmatched].sort()) console.log(`  no line: ${route}: ${numbers.join(", ")}`);
for (const line of suspicious) console.log(`  check: ${line}`);
