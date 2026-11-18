import { strToU8, zipSync } from "fflate";
import { describe, expect, it } from "vitest";
import {
  compileNorthAmericanIntercityGTFSArchive,
  mergeNorthAmericanIntercityGTFSData,
  renderNorthAmericanIntercityGTFSModule,
} from "../scripts/north-american-intercity-gtfs-compiler.js";

function archive(files: Record<string, string>): Uint8Array {
  return zipSync(Object.fromEntries(
    Object.entries(files).map(([name, value]) => [name, strToU8(value)]),
  ));
}

describe("compileNorthAmericanIntercityGTFSArchive", () => {
  it("requires an approval reference before rendering a shippable module", () => {
    expect(() => renderNorthAmericanIntercityGTFSModule({
      feedVersion: "fixture",
      matches: {},
      partialMatches: {},
      shapes: {},
    }, [], {})).toThrow(/approval reference/u);
  });

  it("embeds the approval reference in a promoted module", () => {
    const rendered = renderNorthAmericanIntercityGTFSModule({
      feedVersion: "fixture",
      matches: {},
      partialMatches: {},
      shapes: {},
    }, [], { via: "decision-2026-08-18" });

    expect(rendered).toContain("northAmericanIntercityGTFSDistributionApprovalReferences");
    expect(rendered).toContain("decision-2026-08-18");
  });

  it("refuses to render data for an operator without its own approval", () => {
    expect(() => renderNorthAmericanIntercityGTFSModule({
      feedVersion: "fixture",
      matches: { "brightline|5137|MCO>FBT": "shape" },
      partialMatches: {},
      shapes: { shape: ["abc", 2, "Brightline GTFS"] },
    }, [], { via: "via-approval" })).toThrow(/unapproved operator data/u);
  });

  it("compiles only unambiguous Amtrak rail shapes", () => {
    const result = compileNorthAmericanIntercityGTFSArchive(archive({
      "feed_info.txt": [
        "feed_publisher_name,feed_publisher_url,feed_lang,feed_version",
        "Amtrak,https://www.amtrak.com,en,20260818",
      ].join("\n"),
      "agency.txt": [
        "agency_id,agency_name,agency_url,agency_timezone,agency_lang",
        "51,Amtrak,https://www.amtrak.com,America/New_York,en",
        "157,Via Rail Canada,https://www.viarail.ca,America/New_York,en",
      ].join("\n"),
      "routes.txt": [
        "route_id,agency_id,route_short_name,route_long_name,route_type",
        "rail,51,,Northeast Regional,2",
        "bus,51,,Amtrak Thruway,3",
        "partner,157,,Via Rail,2",
      ].join("\n"),
      "trips.txt": [
        "route_id,service_id,trip_id,trip_short_name,direction_id,shape_id,trip_headsign",
        "rail,weekday,trip-171,171,0,shape-a,Philadelphia",
        "rail,weekend,trip-171-alt,171,0,shape-b,Philadelphia",
        "rail,weekday,trip-172,172,0,shape-a,Philadelphia",
        "bus,weekday,bus-1,9001,0,bus-shape,Somewhere",
        "partner,weekday,partner-1,70,0,partner-shape,Toronto",
      ].join("\n"),
      "stop_times.txt": [
        "trip_id,arrival_time,departure_time,stop_id,stop_sequence",
        "trip-171,10:00:00,10:00:00,NYP,1",
        "trip-171,11:00:00,11:00:00,PHL,2",
        "trip-171-alt,10:00:00,10:00:00,NYP,1",
        "trip-171-alt,11:00:00,11:00:00,PHL,2",
        "trip-172,10:00:00,10:00:00,NYP,1",
        "trip-172,11:00:00,11:00:00,PHL,2",
        "bus-1,10:00:00,10:00:00,NYP,1",
        "bus-1,11:00:00,11:00:00,PHL,2",
        "partner-1,10:00:00,10:00:00,NYP,1",
        "partner-1,11:00:00,11:00:00,PHL,2",
      ].join("\n"),
      "shapes.txt": [
        "shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence",
        "shape-a,40.00000,-74.00000,1",
        "shape-a,39.95000,-75.15000,2",
        "shape-b,40.00000,-74.00000,1",
        "shape-b,39.96000,-75.17000,2",
        "bus-shape,1,1,1",
        "bus-shape,2,2,2",
        "partner-shape,3,3,1",
        "partner-shape,4,4,2",
      ].join("\n"),
    }));

    expect(result.feedVersion).toBe("20260818");
    expect(result.matches["amtrak|172|NYP>PHL"]).toBe("shape-a");
    expect(result.matches["amtrak|171|NYP>PHL"]).toBeUndefined();
    expect(result.partialMatches["amtrak|171"]).toBeUndefined();
    expect(result.partialMatches["amtrak|172"]).toBe("shape-a");
    expect(Object.keys(result.matches)).toEqual(["amtrak|172|NYP>PHL"]);
    expect(Object.keys(result.shapes)).toEqual(["shape-a"]);
    expect(result.shapes["shape-a"]?.[1]).toBe(2);
  });

  it("rejects a feed without the required files", () => {
    expect(() => compileNorthAmericanIntercityGTFSArchive(archive({
      "feed_info.txt": "feed_version\n20260818",
    }))).toThrow(/missing .+\.txt/u);
  });

  it("compiles Brightline without optional feed_info and strips its Amtraker number prefix", () => {
    const result = compileNorthAmericanIntercityGTFSArchive(archive({
      "agency.txt": "agency_id,agency_name,agency_url,agency_timezone\nBL,Brightline,https://www.gobrightline.com,America/New_York",
      "routes.txt": "route_id,agency_id,route_type\n1,BL,2",
      "trips.txt": "route_id,trip_id,trip_short_name,shape_id\n1,trip-5137,5137,2",
      "stop_times.txt": "trip_id,stop_id,stop_sequence\ntrip-5137,MCO,1\ntrip-5137,AVE,2\ntrip-5137,FBT,3",
      "shapes.txt": "shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence\n2,28.4117,-81.3076,1\n2,25.9585,-80.1473,2\n2,26.1236,-80.1455,3",
    }), {
      agencyNames: ["brightline"],
      operator: "brightline",
      shapeIDPrefix: "brightline:",
      source: "Brightline GTFS",
      feedVersionFallback: "2026-08-18T07:00:00Z",
    });

    expect(result.feedVersion).toBe("2026-08-18T07:00:00Z");
    expect(result.matches["brightline|5137|MCO>AVE>FBT"]).toBe("brightline:2");
    expect(result.partialMatches["brightline|5137"]).toBe("brightline:2");
  });

  it("compiles VIA Rail and derives a version from its published service window", () => {
    const result = compileNorthAmericanIntercityGTFSArchive(archive({
      "feed_info.txt": "feed_publisher_name,feed_start_date,feed_end_date\nVIA Rail Canada inc.,20260817,20261217",
      "agency.txt": "agency_name,agency_url,agency_timezone,agency_id\nVIA Rail,https://www.viarail.ca,America/Toronto,1",
      "routes.txt": "route_id,agency_id,route_type\n617-628,1,2",
      "trips.txt": "route_id,trip_id,trip_short_name,shape_id\n617-628,541,20,541",
      "stop_times.txt": "trip_id,stop_id,stop_sequence\n541,226,1\n541,628,2",
      "shapes.txt": "shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence\n541,45.5019,-73.5674,1\n541,46.8139,-71.2080,2",
    }), {
      agencyNames: ["via rail"],
      operator: "via" as never,
      shapeIDPrefix: "via:",
      source: "VIA Rail GTFS",
    });

    expect(result.feedVersion).toBe("20260817-20261217");
    expect(result.matches["via|20|226>628"]).toBe("via:541");
    expect(result.partialMatches["via|20"]).toBe("via:541");
  });

  it("treats duplicate shape identifiers with identical geometry as one safe partial route", () => {
    const result = compileNorthAmericanIntercityGTFSArchive(archive({
      "agency.txt": "agency_id,agency_name,agency_url,agency_timezone\n1,VIA Rail,https://www.viarail.ca,America/Toronto",
      "routes.txt": "route_id,agency_id,route_type\nroute,1,2",
      "trips.txt": "route_id,trip_id,trip_short_name,shape_id\nroute,weekday,26,shape-a\nroute,weekend,26,shape-b",
      "stop_times.txt": "trip_id,stop_id,stop_sequence\nweekday,617,1\nweekday,628,2\nweekend,617,1\nweekend,351,2\nweekend,628,3",
      "shapes.txt": "shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence\nshape-a,45.0,-75.0,1\nshape-a,46.0,-71.0,2\nshape-b,45.0,-75.0,1\nshape-b,46.0,-71.0,2",
    }), {
      agencyNames: ["via rail"],
      operator: "via" as never,
      shapeIDPrefix: "via:",
      source: "VIA Rail GTFS",
    });

    expect(result.partialMatches["via|26"]).toBe("via:shape-a");
  });

  it("drops exact and partial collisions while merging feeds", () => {
    const first = {
      feedVersion: "one",
      matches: { "amtrak|171|NYP>PHL": "one:shape" },
      partialMatches: { "amtrak|171": "one:shape" },
      shapes: { "one:shape": ["abc", 2, "One"] as const },
    };
    const second = {
      feedVersion: "two",
      matches: { "amtrak|171|NYP>PHL": "two:shape" },
      partialMatches: { "amtrak|171": "two:shape" },
      shapes: { "two:shape": ["def", 2, "Two"] as const },
    };

    const result = mergeNorthAmericanIntercityGTFSData([
      { id: "one", data: first },
      { id: "two", data: second },
    ]);

    expect(result.matches).toEqual({});
    expect(result.partialMatches).toEqual({});
    expect(result.shapes).toEqual({});
  });
});
