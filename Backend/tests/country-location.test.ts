import { describe, expect, it } from "vitest";
import { physicalCountryCode } from "../src/providers/country-location.js";

describe("physicalCountryCode", () => {
  it.each([
    ["Brussels", "DE", 50.8354, 4.3357, "BE"],
    ["Madrid", "FR", 40.4064, -3.6909, "ES"],
    ["Baku", "GE", 40.38078, 49.850628, "AZ"],
    ["Budapest-Keleti", "AT", 47.50042, 19.084618, "HU"],
    ["Nendeln", "CH", 47.200203, 9.541627, "LI"],
    ["Luxembourg", "DE", 49.599712, 6.134396, "LU"],
    ["Riga", "LT", 56.9464, 24.122911, "LV"],
    ["Beograd Centar", "ME", 44.79363, 20.453129, "RS"],
    ["Bratislava", "UA", 48.158527, 17.106531, "SK"],
    ["Kyiv", "HU", 50.439445, 30.488056, "UA"],
    ["Feldkirch", "CH", 47.24098, 9.604104, "AT"],
    ["Sargans", "AT", 47.04515, 9.444851, "CH"],
    ["Munich", "AT", 48.14008, 11.557518, "DE"],
    ["Vilnius", "LV", 54.669876, 25.284758, "LT"],
    ["Podgorica", "RS", 42.432007, 19.269415, "ME"],
    ["Tbilisi", "AZ", 41.721054, 44.799587, "GE"],
    ["Baia Mare", "HU", 47.6475, 23.552778, "RO"],
    ["Vámospércs", "RO", 47.518055, 21.893888, "HU"],
    ["Lund C", "DK", 55.708057, 13.186672, "SE"],
    ["Burlöv", "DK", 55.640957, 13.080399, "SE"],
    ["Odense", "DE", 55.401775, 10.386005, "DK"],
    ["Ringsted", "DE", 55.438038, 11.786155, "DK"],
    ["Ljubljana", "AT", 46.05829, 14.511519, "SI"],
    ["Maribor", "AT", 46.56215, 15.657977, "SI"],
  ] as const)("locates %s independently of its source feed", (_name, source, latitude, longitude, expected) => {
    expect(physicalCountryCode(source, latitude, longitude)).toBe(expected);
  });

  it("preserves source evidence at uncertain map boundaries and outside the correction set", () => {
    expect(physicalCountryCode("FR", 43.738414, 7.419747)).toBe("FR"); // Monaco needs station evidence.
    expect(physicalCountryCode("DE", 49.71283, 6.499351)).toBe("DE"); // Wasserbillig, beside the border.
    expect(physicalCountryCode("DE", 49.703255, 6.478645)).toBe("DE"); // Mertert also needs station evidence.
    expect(physicalCountryCode("PT", 38.7223, -9.1393)).toBe("PT");
    expect(physicalCountryCode("XK", 42.6629, 21.1655)).toBe("XK");
    expect(physicalCountryCode("UA", 44.948, 34.1)).toBe("UA"); // No inference about disputed territories.
    expect(physicalCountryCode("DK", 55.609444, 13.000833)).toBe("DK"); // Malmö's harbor needs station evidence.
    expect(physicalCountryCode("DE", 55.672720, 12.564617)).toBe("DE"); // Copenhagen also needs station evidence.
    expect(physicalCountryCode("HR", 45.803, 15.978)).toBe("HR"); // Zagreb is outside Slovenia's polygon.
    expect(physicalCountryCode("NO", 59.91, 10.752)).toBe("NO"); // Oslo is outside Sweden's polygon.
    expect(physicalCountryCode("FI", 60.17, 24.941)).toBe("FI"); // Helsinki is outside Sweden's polygon.
  });

  it("preserves invalid and overseas coordinates without applying European polygons", () => {
    for (const [latitude, longitude] of [[NaN, 4.3], [Infinity, 4.3], [91, 4.3], [45, 181]]) {
      expect(physicalCountryCode("DE", latitude!, longitude!)).toBe("DE");
    }
    expect(physicalCountryCode("GF", 4.9224, -52.3135)).toBe("GF");
    expect(physicalCountryCode("FR", 50.6292, 3.0573)).toBe("FR");
  });
});
