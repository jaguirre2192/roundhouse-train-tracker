import { describe, expect, it } from "vitest";
import { parseDarwinDocument } from "../src/providers/darwin-realtime.js";

const uid = "G15439";
const serviceDate = "2026-07-21";

function forecast(timestamp: string, location: string): string {
  return `<Pport ts="${timestamp}"><uR>
    <TS rid="202607217154439" uid="${uid}" ssd="${serviceDate}">${location}</TS>
  </uR></Pport>`;
}

describe("Darwin late-running reasons", () => {
  it("clears a late-reason alert once a later forecast no longer gives one", () => {
    const late = parseDarwinDocument(forecast("2026-07-21T21:42:30+01:00", `
      <ns5:Location tpl="PADTON"><ns5:dep et="22:05" /><ns5:LateReason>734</ns5:LateReason></ns5:Location>`),
    uid, serviceDate);
    expect([...late?.alertIds ?? []]).toContain("darwin-late-734");

    const recovered = parseDarwinDocument(forecast("2026-07-21T21:50:00+01:00", `
      <ns5:Location tpl="PADTON"><ns5:dep et="22:00" /></ns5:Location>`),
    uid, serviceDate, late);

    expect([...recovered?.alertIds ?? []].filter((id) => id.startsWith("darwin-late-"))).toEqual([]);
  });

  it("replaces the reason when Darwin restates a different one", () => {
    const first = parseDarwinDocument(forecast("2026-07-21T21:42:30+01:00",
      `<ns5:LateReason>734</ns5:LateReason><ns5:Location tpl="PADTON"><ns5:dep et="22:05" /></ns5:Location>`),
    uid, serviceDate);
    const second = parseDarwinDocument(forecast("2026-07-21T21:45:00+01:00",
      `<ns5:LateReason>812</ns5:LateReason><ns5:Location tpl="PADTON"><ns5:dep et="22:09" /></ns5:Location>`),
    uid, serviceDate, first);

    expect([...second?.alertIds ?? []].filter((id) => id.startsWith("darwin-late-"))).toEqual(["darwin-late-812"]);
  });
});
