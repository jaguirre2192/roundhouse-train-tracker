import { describe, expect, it } from "vitest";
import { decodePolyline5, encodePolyline5, type PolylineCoordinate } from "../src/providers/encoded-polyline.js";
import { FirstMatchingRouteGeometrySource, NTADAmtrakRouteGeometrySource } from "../src/providers/ntad-amtrak-route-geometry.js";
import { ntadAmtrakRoutesSourceLabel, type NTADAmtrakRouteNetworkData } from "../src/providers/ntad-amtrak-routes-model.js";
import {
  ntadAmtrakRouteNetwork,
  ntadAmtrakRoutesSourceSHA256,
} from "../src/providers/ntad-amtrak-routes.generated.js";

function line(...points: Array<[number, number]>): [string, number] {
  return [encodePolyline5(points.map(([latitude, longitude]) => ({ latitude, longitude }))), points.length];
}

function stop(code: string, latitude: number | null, longitude: number | null) {
  return { code, latitude, longitude };
}

function lengthKilometres(points: readonly PolylineCoordinate[]): number {
  let total = 0;
  for (let index = 1; index < points.length; index += 1) {
    const a = points[index - 1]!;
    const b = points[index]!;
    const r = Math.PI / 180;
    const h = Math.sin((b.latitude - a.latitude) * r / 2) ** 2
      + Math.cos(a.latitude * r) * Math.cos(b.latitude * r) * Math.sin((b.longitude - a.longitude) * r / 2) ** 2;
    total += 2 * 6_371 * Math.asin(Math.sqrt(h));
  }
  return total;
}

// A junction at (40, -75) with three arms: west to (40, -76), north-east to (41, -74) and
// south-east to (39, -74). Each arm bends once, so a path along it is not a straight line.
const fork: NTADAmtrakRouteNetworkData = {
  edges: [
    line([40, -76], [40.1, -75.5], [40, -75]),
    line([40, -75], [40.6, -74.6], [41, -74]),
    line([39, -74], [39.4, -74.6], [40, -75]),
  ],
  routes: [{ name: "Fork", bounds: [39, -76, 41, -74], edges: [[0, 0, 1], [1, 1, 2], [2, 3, 1]] }],
};

describe("NTADAmtrakRouteGeometrySource", () => {
  it("follows the branch the stops are on, through the junction and along each bend", async () => {
    const source = new NTADAmtrakRouteGeometrySource(fork);
    const geometry = await source.geometryFor("Amtrak", "1", [
      stop("WST", 40, -76), stop("JCT", 40, -75), stop("SE", 39, -74),
    ]);
    expect(geometry?.source).toBe(ntadAmtrakRoutesSourceLabel);
    const segment = geometry!.segments[0]!;
    const path = decodePolyline5(segment.encodedPolyline, segment.pointCount)!;
    expect(path.map((point) => [point.latitude, point.longitude])).toEqual([
      [40, -76], [40.1, -75.5], [40, -75], [39.4, -74.6], [39, -74],
    ]);
  });

  it("starts and ends part-way along an edge at the stops themselves", async () => {
    const source = new NTADAmtrakRouteGeometrySource(fork);
    const geometry = await source.geometryFor("Amtrak", "2", [stop("A", 40.3, -74.8), stop("B", 40.8, -74.3)]);
    const segment = geometry!.segments[0]!;
    const path = decodePolyline5(segment.encodedPolyline, segment.pointCount)!;
    expect(path).toHaveLength(3);
    expect(path[1]).toEqual({ latitude: 40.6, longitude: -74.6 });
    expect(path[0]!.latitude).toBeCloseTo(40.3, 1);
    expect(path.at(-1)!.latitude).toBeCloseTo(40.8, 1);
  });

  it("returns nothing rather than guess", async () => {
    const source = new NTADAmtrakRouteGeometrySource(fork);
    // Another operator, a stop off the line, a stop without coordinates, a single stop.
    await expect(source.geometryFor("Brightline", "1", [stop("A", 40, -76), stop("B", 40, -75)])).resolves.toBeNull();
    await expect(source.geometryFor("Amtrak", "1", [stop("A", 40, -76), stop("B", 40.5, -75.9)])).resolves.toBeNull();
    await expect(source.geometryFor("Amtrak", "1", [stop("A", 40, -76), stop("B", null, null), stop("C", 39, -74)])).resolves.toBeNull();
    await expect(source.geometryFor("Amtrak", "1", [stop("A", 40, -76)])).resolves.toBeNull();
  });

  it("refuses a path that doubles back far beyond the distance between two stops", async () => {
    // A horseshoe: the two stops are 2 km apart but 220 km apart along the only line.
    const horseshoe: NTADAmtrakRouteNetworkData = {
      edges: [line([40, -75], [41, -75], [41, -74.98], [40, -74.98])],
      routes: [{ name: "Horseshoe", bounds: [40, -75, 41, -74.98], edges: [[0, 0, 1]] }],
    };
    const source = new NTADAmtrakRouteGeometrySource(horseshoe);
    await expect(source.geometryFor("Amtrak", "1", [stop("A", 40, -75), stop("B", 40, -74.98)])).resolves.toBeNull();
  });
});

describe("the compiled federal Amtrak route network", () => {
  const source = new NTADAmtrakRouteGeometrySource(ntadAmtrakRouteNetwork);
  // Station positions are public facts; the rail distance New York to Washington is 363 km.
  const corridor = [
    stop("NYP", 40.7506, -73.9935), stop("PHL", 39.9557, -75.182), stop("WIL", 39.7369, -75.5517),
    stop("BAL", 39.3076, -76.6156), stop("WAS", 38.8973, -77.0063),
  ];

  it("records its provenance", () => {
    expect(ntadAmtrakRoutesSourceSHA256).toMatch(/^[a-f0-9]{64}$/u);
    expect(ntadAmtrakRouteNetwork.routes.length).toBeGreaterThanOrEqual(40);
    expect(ntadAmtrakRouteNetwork.routes.map((route) => route.name)).toContain("Northeast Regional");
  });

  it("draws the Northeast Corridor at its real length in both directions", async () => {
    for (const stops of [corridor, [...corridor].reverse()]) {
      const geometry = await source.geometryFor("Amtrak", "171", stops);
      const segment = geometry!.segments[0]!;
      const path = decodePolyline5(segment.encodedPolyline, segment.pointCount)!;
      expect(path.length).toBeGreaterThan(200);
      expect(lengthKilometres(path)).toBeGreaterThan(352);
      expect(lengthKilometres(path)).toBeLessThan(374);
    }
  });

  it("has no route joining New York to Seattle", async () => {
    await expect(source.geometryFor("Amtrak", "999", [corridor[0]!, stop("SEA", 47.5984, -122.3301)])).resolves.toBeNull();
  });
});

describe("FirstMatchingRouteGeometrySource", () => {
  it("asks each source in order and survives one that throws", async () => {
    const calls: string[] = [];
    const answer = { source: "second", segments: [] };
    const combined = new FirstMatchingRouteGeometrySource([
      { geometryFor: async () => { calls.push("first"); throw new Error("unavailable"); } },
      { geometryFor: async () => { calls.push("second"); return answer; } },
      { geometryFor: async () => { calls.push("third"); return null; } },
    ]);
    await expect(combined.geometryFor("Amtrak", "1", [])).resolves.toBe(answer);
    expect(calls).toEqual(["first", "second"]);
  });
});
