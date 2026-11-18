import { describe, expect, it } from "vitest";
import { publishedAmtrakName } from "../src/providers/transitous-amtrak-name.js";

describe("named Amtrak services in a numeric Transitous display", () => {
  it.each([["281", "Empire Service"], ["63", "Maple Leaf"], ["69", "Adirondack"]])(
    "keeps the operator's name alongside train %s", (number, name) => {
      expect(publishedAmtrakName({ tripId: "20261118_10:20_us-Amtrak_317549", displayName: number,
        tripShortName: number, routeLongName: name })).toBe(name + " " + number);
    });
  it("preserves another railway's numeric displays and an existing named product", () => {
    expect(publishedAmtrakName({ agencyName: "RENFE", displayName: "281", routeLongName: "A Coruña" })).toBeNull();
    expect(publishedAmtrakName({ agencyName: "Amtrak", displayName: "Acela 2172", routeLongName: "Acela" })).toBeNull();
    expect(publishedAmtrakName({ agencyName: "Amtrak", displayName: "281" })).toBeNull();
    expect(publishedAmtrakName({ agencyName: "Amtrak", displayName: "281", routeLongName: "Empire Service 281" })).toBe("Empire Service 281");
  });
});
