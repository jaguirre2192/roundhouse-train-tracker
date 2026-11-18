import { z } from "zod";

const identifier = z.number().int().positive().max(Number.MAX_SAFE_INTEGER);
const clock = z.string().regex(/^(?:[01]\d|2[0-3]):[0-5]\d$/u);

const stop = z.object({
  iD_VOZ: identifier,
  rb: identifier,
  sifrA_STANICE: identifier,
  vremE_DOLASKA: clock,
  vremE_POLASKA: clock,
  naziV_STANICE: z.string().trim().min(1).max(160),
});

export const srbijaVozConnections = z.array(z.object({
  odsifra: identifier,
  dosifra: identifier,
  idvoz: identifier,
  brvoz: identifier,
  rangs: z.string().trim().min(1).max(20),
  soko: z.boolean(),
  vremep: clock,
  vremed: clock,
  trajanje_putovanja: z.string().regex(/^\d{2}:[0-5]\d$/u),
  datum_dolaska: z.string().regex(/^\d{4}-\d{2}-\d{2}T00:00:00(?:\.000)?$/u),
  etTrasaVoza: z.array(stop).min(2).max(150),
})).max(250);

export type SrbijaVozConnection = z.infer<typeof srbijaVozConnections>[number];
export type SrbijaVozStop = SrbijaVozConnection["etTrasaVoza"][number];

export function isSrbijaVozMainline(connection: SrbijaVozConnection): boolean {
  return ["IC", "IR", "Re", "REx"].includes(connection.rangs);
}
