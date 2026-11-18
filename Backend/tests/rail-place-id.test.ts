import { describe, expect, it } from "vitest";
import {
  decodeRailPlaceId,
  encodeRailPlaceId,
  type DecodedRailPlaceId,
} from "../src/providers/rail-place-id.js";

const city: DecodedRailPlaceId = {
  provider: "transitous",
  kind: "city",
  nativeId: "node/[17807753]",
  countryCode: "FR",
  latitude: 48.853495,
  longitude: 2.348392,
};

function encoded(kind: "city" | "station", fields: string[]): string {
  return `rail:transitous:${kind}:${Buffer.from(fields.join("\u001f"), "utf8").toString("base64url")}`;
}

describe("rail place IDs", () => {
  it("round-trips canonical city and exact-station identifiers", () => {
    const station: DecodedRailPlaceId = {
      provider: "transitous",
      kind: "station",
      nativeId: "ch-opentransportdataswiss26_Parent8768600",
      countryCode: "FR",
      latitude: null,
      longitude: null,
    };

    const cityId = encodeRailPlaceId(city);
    const stationId = encodeRailPlaceId(station);

    expect(cityId).toMatch(/^rail:transitous:city:[A-Za-z0-9_-]+$/u);
    expect(stationId).toMatch(/^rail:transitous:station:[A-Za-z0-9_-]+$/u);
    expect(decodeRailPlaceId(cityId)).toEqual(city);
    expect(decodeRailPlaceId(stationId)).toEqual(station);
  });

  it("preserves negative zero as a reversible valid coordinate", () => {
    const zeroMeridian = { ...city, longitude: -0 };

    expect(Object.is(decodeRailPlaceId(encodeRailPlaceId(zeroMeridian)).longitude, -0)).toBe(true);
  });

  it("round-trips Serbian station IDs without changing existing Transitous IDs", () => {
    const station: DecodedRailPlaceId = {
      provider: "srbijavoz", kind: "station", nativeId: "fixture-station:123",
      countryCode: "RS", latitude: null, longitude: null,
    };
    const encodedStation = encodeRailPlaceId(station);
    expect(encodedStation).toMatch(/^rail:srbijavoz:station:[A-Za-z0-9_-]+$/u);
    expect(decodeRailPlaceId(encodedStation)).toEqual(station);
    expect(encodedStation.replace("rail:srbijavoz:", "rail:transitous:")).toBe(
      encodeRailPlaceId({ ...station, provider: "transitous" }),
    );
    const existing = "rail:transitous:station:c2stenNyXzU2MTM2NzYfU0sfHw";
    expect(encodeRailPlaceId(decodeRailPlaceId(existing))).toBe(existing);
    expect(decodeRailPlaceId(existing)).toMatchObject({ provider: "transitous", nativeId: "sk-zsr_5613676", countryCode: "SK" });
  });

  it("limits Serbian IDs to exact stations in Serbia on both encoding and decoding", () => {
    const station: DecodedRailPlaceId = {
      provider: "srbijavoz", kind: "station", nativeId: "fixture-station",
      countryCode: "RS", latitude: null, longitude: null,
    };
    expect(() => encodeRailPlaceId({ ...station, countryCode: "SK" })).toThrow("Invalid rail place ID");
    expect(() => encodeRailPlaceId({ ...station, kind: "city", latitude: 44.8, longitude: 20.4 })).toThrow("Invalid rail place ID");
    expect(() => encodeRailPlaceId({ ...station, latitude: 44.8, longitude: 20.4 })).toThrow("Invalid rail place ID");
    const invalid = [
      encoded("station", [station.nativeId, "SK", "", ""]),
      encoded("city", [station.nativeId, "RS", "44.8", "20.4"]),
      encoded("station", [station.nativeId, "RS", "44.8", "20.4"]),
    ];
    for (const value of invalid) {
      expect(() => decodeRailPlaceId(value.replace("rail:transitous:", "rail:srbijavoz:"))).toThrow("Invalid rail place ID");
    }
    expect(() => decodeRailPlaceId(encodeRailPlaceId(station).replace("srbijavoz", "unsupported"))).toThrow("Invalid rail place ID");
  });

  it("enforces canonical field and identifier bounds", () => {
    const maximumNativeId = { ...city, nativeId: "a".repeat(500) };

    expect(decodeRailPlaceId(encodeRailPlaceId(maximumNativeId))).toEqual(maximumNativeId);
    expect(() => encodeRailPlaceId({ ...city, nativeId: "a".repeat(501) })).toThrow("Invalid rail place ID");
    expect(() => encodeRailPlaceId({ ...city, countryCode: "fr" })).toThrow("Invalid rail place ID");
    expect(() => encodeRailPlaceId({ ...city, nativeId: "bad\u001fseparator" })).toThrow("Invalid rail place ID");
    expect(() => decodeRailPlaceId(`rail:transitous:city:${"a".repeat(980)}`)).toThrow("Invalid rail place ID");
    expect(() => decodeRailPlaceId("rail:transitous:city:not+base64")).toThrow("Invalid rail place ID");
  });

  it.each([
    ["high", "\ud800"],
    ["low", "\udc00"],
  ])("rejects a native ID containing a lone %s surrogate", (_kind, surrogate) => {
    expect(() => encodeRailPlaceId({ ...city, nativeId: `broken-${surrogate}` })).toThrow("Invalid rail place ID");
  });

  it("rejects malformed, missing, non-finite, and out-of-range coordinates", () => {
    expect(() => decodeRailPlaceId(encoded("city", [city.nativeId, "FR", "", "2.3"]))).toThrow("Invalid rail place ID");
    expect(() => decodeRailPlaceId(encoded("city", [city.nativeId, "FR", "NaN", "2.3"]))).toThrow("Invalid rail place ID");
    expect(() => decodeRailPlaceId(encoded("city", [city.nativeId, "FR", "91", "2.3"]))).toThrow("Invalid rail place ID");
    expect(() => decodeRailPlaceId(encoded("city", [city.nativeId, "FR", "48.8", "181"]))).toThrow("Invalid rail place ID");
    expect(() => decodeRailPlaceId(encoded("station", [city.nativeId, "FR", "48.8", "2.3"]))).toThrow("Invalid rail place ID");
    expect(() => encodeRailPlaceId({ ...city, latitude: Number.POSITIVE_INFINITY })).toThrow("Invalid rail place ID");
    expect(() => encodeRailPlaceId({ ...city, longitude: -181 })).toThrow("Invalid rail place ID");
  });
});
