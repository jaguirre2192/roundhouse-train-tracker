import { describe, expect, it } from "vitest";
import { gunzipDarwinTripDocument } from "../src/cloudflare/darwin-ftp.js";
import { parseDarwinDocument } from "../src/providers/darwin-realtime.js";

async function gzip(value: string): Promise<Uint8Array> {
  const stream = new Blob([value]).stream().pipeThrough(new CompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

describe("Darwin FTP stream filtering", () => {
  it("retains only the requested service before parsing the snapshot", async () => {
    const unrelated = Array.from({ length: 2_000 }, (_, index) => `
      <schedule rid="other-${index}" uid="X${String(index).padStart(5, "0")}" ssd="2026-08-08">
        <ns2:OR tpl="OTHER${index}" />
      </schedule>`).join("");
    const source = `<Pport ts="2026-08-08T18:00:00.0000000+01:00"><uR>
      ${unrelated}
      <schedule rid="target" uid="G15439" ssd="2026-08-08">
        <ns2:OR tpl="PADTON" />
      </schedule>
      <TS rid="target" uid="G15439" ssd="2026-08-08">
        <ns5:Location tpl="PADTON"><ns5:dep et="18:05" /><ns5:plat>9</ns5:plat></ns5:Location>
      </TS>
      <trainAlert><ns8:AlertID>4079</ns8:AlertID>
        <ns8:AlertService RID="target" UID="G15439" SSD="2026-08-08" />
      </trainAlert>
    </uR></Pport>`;

    const filtered = await gunzipDarwinTripDocument(await gzip(source), "G15439", "2026-08-08");
    const state = parseDarwinDocument(filtered, "G15439", "2026-08-08");

    expect(filtered.length).toBeLessThan(1_000);
    expect(filtered).not.toContain("OTHER1999");
    expect(state?.locations.get("PADTON")).toMatchObject({
      expectedDeparture: "18:05",
      platform: "9",
    });
    expect(state?.alertIds).toContain("darwin-train-alert-4079");
  });
});
