import { describe, expect, it } from "vitest";
import {
  NorthAmericanIntercityGTFSGeometryCatalog,
  type NorthAmericanIntercityGTFSGeometryData,
} from "../src/providers/north-american-intercity-gtfs-geometry.js";
import {
  northAmericanIntercityGTFSDistributionApprovalReferences,
  northAmericanIntercityGTFSFeedMetadata,
  northAmericanIntercityGTFSFeedVersion,
  northAmericanIntercityGTFSMatches,
  northAmericanIntercityGTFSPartialMatches,
  northAmericanIntercityGTFSShapes,
} from "../src/providers/north-american-intercity-gtfs-shapes.approved.js";
import { encodePolyline5 } from "../src/providers/encoded-polyline.js";

const geometryData: NorthAmericanIntercityGTFSGeometryData = {
  feedVersion: "fixture-2026-08-18",
  matches: {
    "amtrak|171|NYP>PHL": "shape-171",
    "brightline|5137|MCO>AVE>FBT": "shape-brightline",
    "via|20|MTRL>QBEC": "shape-via",
  },
  partialMatches: {
    "amtrak|171": "shape-171",
    "brightline|5137": "shape-brightline",
    "via|20": "shape-via",
  },
  shapes: {
    "shape-171": ["_p~iF~ps|U_ulLnnqC_mqNvxq`@", 3, "Amtrak GTFS"],
    "shape-brightline": ["_p~iF~ps|U_ulLnnqC_mqNvxq`@", 3, "Brightline GTFS"],
    "shape-via": ["_p~iF~ps|U_ulLnnqC_mqNvxq`@", 3, "VIA Rail GTFS"],
  },
};

function fixtureCatalog(): NorthAmericanIntercityGTFSGeometryCatalog {
  return new NorthAmericanIntercityGTFSGeometryCatalog({
    data: geometryData,
    enabledOperators: ["amtrak", "brightline", "via" as never],
  });
}

describe("NorthAmericanIntercityGTFSGeometryCatalog", () => {
  it("denies every operator unless the caller explicitly enables it", async () => {
    const catalog = new NorthAmericanIntercityGTFSGeometryCatalog({ data: geometryData });

    await expect(catalog.geometryFor("Amtrak", "171", [
      { code: "NYP", latitude: null, longitude: null },
      { code: "PHL", latitude: null, longitude: null },
    ])).resolves.toBeNull();
  });

  it("refuses to activate the shipped catalog without a distribution approval", () => {
    if (northAmericanIntercityGTFSDistributionApprovalReferences.brightline !== undefined) return;
    expect(() => new NorthAmericanIntercityGTFSGeometryCatalog({ enabledOperators: ["brightline"] }))
      .toThrow(/distribution approval/u);
  });

  it("returns official geometry for an exact normalized train and stop sequence", async () => {
    const catalog = fixtureCatalog();

    await expect(catalog.geometryFor("Amtrak", "0171", [
      { code: " nyp ", latitude: null, longitude: null },
      { code: "phl", latitude: null, longitude: null },
    ])).resolves.toEqual({
      source: "Amtrak GTFS",
      segments: [{
        encodedPolyline: "_p~iF~ps|U_ulLnnqC_mqNvxq`@",
        precision: 5,
        pointCount: 3,
      }],
    });
  });

  it("abstains when the ordered stop sequence is partial or different", async () => {
    const catalog = fixtureCatalog();

    await expect(catalog.geometryFor("Amtrak", "171", [
      { code: "NYP", latitude: null, longitude: null },
    ])).resolves.toBeNull();
    await expect(catalog.geometryFor("Amtrak", "171", [
      { code: "PHL", latitude: null, longitude: null },
      { code: "NYP", latitude: null, longitude: null },
    ])).resolves.toBeNull();
    await expect(catalog.geometryFor("Amtrak", "172", [
      { code: "NYP", latitude: null, longitude: null },
      { code: "PHL", latitude: null, longitude: null },
    ])).resolves.toBeNull();
  });

  it("clips a unique train shape to trustworthy partial-trip endpoints", async () => {
    const catalog = fixtureCatalog();

    const geometry = await catalog.geometryFor("Amtrak", "171", [
      { code: "MID", latitude: 40.7, longitude: -120.95 },
      { code: "END", latitude: 43.252, longitude: -126.453 },
    ]);

    expect(geometry?.segments[0]?.pointCount).toBe(2);
    expect(geometry?.segments[0]?.encodedPolyline).not.toBe(geometryData.shapes["shape-171"]?.[0]);
  });

  it("abstains from partial matching when endpoints are off the official shape", async () => {
    const catalog = fixtureCatalog();

    await expect(catalog.geometryFor("Amtrak", "171", [
      { code: "MID", latitude: 0, longitude: 0 },
      { code: "END", latitude: 1, longitude: 1 },
    ])).resolves.toBeNull();
  });

  it("normalizes Brightline's Amtraker prefix without crossing operator namespaces", async () => {
    const catalog = fixtureCatalog();
    const stops = [
      { code: "MCO", latitude: null, longitude: null },
      { code: "AVE", latitude: null, longitude: null },
      { code: "FBT", latitude: null, longitude: null },
    ];

    await expect(catalog.geometryFor("Brightline", "b5137", stops))
      .resolves.toMatchObject({ source: "Brightline GTFS" });
    await expect(catalog.geometryFor("Amtrak", "b5137", stops)).resolves.toBeNull();
    await expect(catalog.geometryFor("VIA Rail", "v5137", stops)).resolves.toBeNull();
  });

  it("normalizes VIA's Amtraker prefix without crossing operator namespaces", async () => {
    const catalog = fixtureCatalog();
    const stops = [
      { code: "MTRL", latitude: null, longitude: null },
      { code: "QBEC", latitude: null, longitude: null },
    ];

    await expect(catalog.geometryFor("Via", "v20", stops))
      .resolves.toMatchObject({ source: "VIA Rail GTFS" });
    await expect(catalog.geometryFor("Amtrak", "v20", stops)).resolves.toBeNull();
  });

  it("requires every located partial-trip stop to progress along the same shape", async () => {
    const catalog = fixtureCatalog();

    await expect(catalog.geometryFor("Amtrak", "171", [
      { code: "START", latitude: 38.5, longitude: -120.2 },
      { code: "DETOUR", latitude: 43.252, longitude: -126.453 },
      { code: "END", latitude: 40.7, longitude: -120.95 },
    ])).resolves.toBeNull();
  });

  it("matches repeated station coordinates around an official reversal", async () => {
    const loopData: NorthAmericanIntercityGTFSGeometryData = {
      feedVersion: "loop",
      matches: {},
      partialMatches: { "amtrak|40": "shape-loop" },
      shapes: {
        "shape-loop": [encodePolyline5([
          { latitude: 0, longitude: 0 },
          { latitude: 0, longitude: 1.0004 },
          { latitude: 1, longitude: 1 },
          { latitude: 0, longitude: 1 },
          { latitude: 0, longitude: 2 },
        ]), 5, "Amtrak GTFS"],
      },
    };
    const catalog = new NorthAmericanIntercityGTFSGeometryCatalog({
      data: loopData,
      enabledOperators: ["amtrak"],
    });

    await expect(catalog.geometryFor("Amtrak", "40", [
      { code: "START", latitude: 0, longitude: 0 },
      { code: "LAK", latitude: 0, longitude: 1 },
      { code: "TPA", latitude: 1, longitude: 1 },
      { code: "LKL", latitude: 0, longitude: 1 },
      { code: "END", latitude: 0, longitude: 2 },
    ])).resolves.toMatchObject({
      segments: [{ pointCount: 5 }],
    });
  });

  it("can restrict enabled operators independently", async () => {
    const catalog = new NorthAmericanIntercityGTFSGeometryCatalog({
      data: geometryData,
      enabledOperators: ["brightline"],
    });

    await expect(catalog.geometryFor("Amtrak", "171", [
      { code: "NYP", latitude: null, longitude: null },
      { code: "PHL", latitude: null, longitude: null },
    ])).resolves.toBeNull();
  });

  it("keeps the shipped catalog consistent with its embedded approval state", () => {
    if (Object.keys(northAmericanIntercityGTFSDistributionApprovalReferences).length === 0) {
      expect(northAmericanIntercityGTFSFeedVersion).toBe("unapproved");
      expect(northAmericanIntercityGTFSMatches).toEqual({});
      expect(northAmericanIntercityGTFSPartialMatches).toEqual({});
      expect(northAmericanIntercityGTFSShapes).toEqual({});
      expect(northAmericanIntercityGTFSFeedMetadata).toEqual([]);
      return;
    }

    expect(northAmericanIntercityGTFSFeedVersion).toContain("via:");
    expect(Object.keys(northAmericanIntercityGTFSMatches).length).toBeGreaterThan(20);
    expect(Object.keys(northAmericanIntercityGTFSPartialMatches).length).toBeGreaterThan(20);
    expect(Object.keys(northAmericanIntercityGTFSShapes).length).toBeGreaterThan(20);
    expect(northAmericanIntercityGTFSFeedMetadata.map((feed) => feed.id)).toEqual(["via"]);
    expect(northAmericanIntercityGTFSFeedMetadata.every((feed) => /^[a-f0-9]{64}$/u.test(feed.sha256))).toBe(true);
    expect(northAmericanIntercityGTFSDistributionApprovalReferences.via).toContain("viarail.ca");
    expect(Object.keys(northAmericanIntercityGTFSMatches).every((key) => key.startsWith("via|"))).toBe(true);
  });
});
