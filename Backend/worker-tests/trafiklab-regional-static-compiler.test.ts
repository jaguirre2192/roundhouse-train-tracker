import { describe, expect, it } from "vitest";
import { compileTrafiklabRegionalStatic } from "../src/providers/trafiklab-regional-static-compiler.js";
import { fixtureStream, regionalStaticFixture } from "./fixtures/trafiklab-regional-static.js";

describe("regional static compiler in workerd", () => {
  it("streams an adverse-order ZIP into the same compact rail/platform schema", async () => {
    const index = await compileTrafiklabRegionalStatic(fixtureStream(regionalStaticFixture(), 7));
    expect(index.trips).toEqual([["1001", "1231", 0, [[1, 1, 85800, 85800], [4, 2, 87600, 87600]]]]);
    expect(index.stations).toHaveLength(5);
    expect(index.sourceHashes.regional).toMatch(/^[a-f0-9]{64}$/u);
  });

  it("honors cancellation and byte limits using Worker streams", async () => {
    const signal = AbortSignal.abort(new Error("deadline"));
    await expect(compileTrafiklabRegionalStatic(fixtureStream(regionalStaticFixture()), { signal })).rejects.toThrow("deadline");
    await expect(compileTrafiklabRegionalStatic(fixtureStream(regionalStaticFixture()), { maxSelectedCompressedBytes: 20 })).rejects.toThrow("Oversized");
  });
});
