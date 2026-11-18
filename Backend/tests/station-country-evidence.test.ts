import { describe, expect, it } from "vitest";
import { evidencedStationCountryCode } from "../src/providers/station-country-evidence.js";
import { transitousPlaceCountryCode } from "../src/providers/transitous-country.js";

describe("station country evidence", () => {
  it.each([
    ["Monaco-Monte-Carlo", 43.738414, 7.419747, "MC"],
    ["Gare de Monaco - Pont Sainte Dévote", 43.738415, 7.419747, "MC"],
    ["Wasserbillig", 49.71283, 6.499351, "LU"],
    ["Mertert", 49.703255, 6.478645, "LU"],
    ["Buchs Bahnhof", 47.169014, 9.478519, "CH"],
    ["Freilassing Bahnhof", 47.836937, 12.97655, "DE"],
    ["VENTIMIGLIA", 43.792569, 7.610233, "IT"],
    ["Malmö C", 55.609444, 13.000833, "SE"],
    ["Koebenhavn H", 55.672720, 12.564617, "DK"],
    ["København H", 55.673058, 12.565558, "DK"],
  ] as const)("resolves %s with both station identity and coordinates", (name, lat, lon, expected) => {
    expect(evidencedStationCountryCode(name, lat, lon)).toBe(expected);
    expect(transitousPlaceCountryCode({ name, stopId: "xx-foreign-feed_opaque", lat, lon })).toBe(expected);
  });

  it("does not expand station evidence into a geographic or name-only override", () => {
    expect(evidencedStationCountryCode("Monaco-Monte-Carlo", 43.76, 7.42)).toBeUndefined();
    expect(evidencedStationCountryCode("Cap-d'Ail", 43.738414, 7.419747)).toBeUndefined();
    expect(evidencedStationCountryCode(undefined, 43.738414, 7.419747)).toBeUndefined();
    expect(evidencedStationCountryCode("Wasserbillig", NaN, 6.499351)).toBeUndefined();
    expect(evidencedStationCountryCode("Wasserbillig", 49.71283, Infinity)).toBeUndefined();
    expect(evidencedStationCountryCode("Buchs ZH", 47.458, 8.435)).toBeUndefined();
    expect(evidencedStationCountryCode("Mertert", 49.7, 6.5)).toBeUndefined();
    expect(evidencedStationCountryCode("Malmö C", 55.673058, 12.565558)).toBeUndefined();
    expect(evidencedStationCountryCode("København H", 55.609444, 13.000833)).toBeUndefined();
    expect(evidencedStationCountryCode("Malmö Hyllie", 55.609444, 13.000833)).toBeUndefined();
    expect(evidencedStationCountryCode("Malmö C", 55.62, 13.000833)).toBeUndefined();
  });

  it("uses exact station evidence ahead of conflicting publisher metadata and handles placeholders", () => {
    const place = { name: "Monaco-Monte-Carlo", stopId: "fr-foreign-feed_opaque", lat: 43.738414, lon: 7.419747 };
    expect(transitousPlaceCountryCode({ ...place, country: " mc " })).toBe("MC");
    expect(transitousPlaceCountryCode({ ...place, country: "FR" })).toBe("MC");
    for (const country of [null, "", "XX", "EU", "France"]) {
      expect(transitousPlaceCountryCode({ ...place, country })).toBe("MC");
    }
  });
});
