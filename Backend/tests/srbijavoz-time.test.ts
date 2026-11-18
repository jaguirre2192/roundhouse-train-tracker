import { describe, expect, it } from "vitest";
import { srbijaVozDateAt, srbijaVozInstant, shiftSrbijaVozDate, validSrbijaVozDate } from "../src/providers/srbijavoz-time.js";
import { mapSrbijaVozConnection } from "../src/providers/srbijavoz-mapper.js";

describe("Serbian timetable wall clocks", () => {
  it("converts Serbia's winter/summer offsets and its local date boundary", () => {
    expect(srbijaVozInstant("2026-11-13", "12:00")).toBe("2026-11-13T11:00:00.000Z");
    expect(srbijaVozInstant("2026-07-13", "12:00")).toBe("2026-07-13T10:00:00.000Z");
    expect(srbijaVozDateAt("2026-11-13T23:30:00Z")).toBe("2026-11-14");
    expect(shiftSrbijaVozDate("2026-12-31", 1)).toBe("2027-01-01");
    expect(validSrbijaVozDate("2026-02-29")).toBe(false);
    expect(validSrbijaVozDate("2028-02-29")).toBe(true);
  });

  it("rejects nonexistent spring times and uses the first repeated autumn hour", () => {
    expect(() => srbijaVozInstant("2026-03-29", "02:30")).toThrow("wall clock");
    expect(srbijaVozInstant("2026-10-25", "02:30")).toBe("2026-10-25T00:30:00.000Z");
    expect(() => srbijaVozInstant("2026-11-13", "24:00")).toThrow();
  });

  it("checks elapsed journey duration across the spring transition", () => {
    const row = {
      odsifra: 16052, dosifra: 16807, idvoz: 1, brvoz: 1, rangs: "IC", soko: true,
      vremep: "01:30", vremed: "03:15", trajanje_putovanja: "00:45", datum_dolaska: "2026-03-29T00:00:00",
      etTrasaVoza: [
        { iD_VOZ: 1, rb: 1, sifrA_STANICE: 16052, naziV_STANICE: "Beograd Centar", vremE_DOLASKA: "01:30", vremE_POLASKA: "01:30" },
        { iD_VOZ: 1, rb: 2, sifrA_STANICE: 16807, naziV_STANICE: "Petrovaradin", vremE_DOLASKA: "03:15", vremE_POLASKA: "03:15" },
      ],
    };
    const mapped = mapSrbijaVozConnection(row, "2026-03-29", "2026-03-28T12:00:00Z");
    expect(mapped?.option.duration).toBe(45 * 60);
    expect(mapSrbijaVozConnection({ ...row, trajanje_putovanja: "01:45" }, "2026-03-29", "2026-03-28T12:00:00Z")).toBeNull();
  });
});
