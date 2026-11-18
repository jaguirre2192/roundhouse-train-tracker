export const maintenancePhases = ["reserved", "static-request", "static-response", "compiling",
  "validation", "publish-request", "publish-response"] as const;
export interface RegionalMaintenanceDiagnostics {
  phase: typeof maintenancePhases[number] | null;
  httpStatus: number | null;
  redirectStatus: number | null;
  downloadBytes: number | null;
  downloadComplete: boolean | null;
}
export type ReportMaintenanceDiagnostics = (value: Partial<RegionalMaintenanceDiagnostics>) => void;

export function unknownMaintenanceDiagnostics(): RegionalMaintenanceDiagnostics {
  return { phase: null, httpStatus: null, redirectStatus: null, downloadBytes: null, downloadComplete: null };
}

export function parseMaintenanceDiagnostics(value: unknown): RegionalMaintenanceDiagnostics | null {
  if (value === undefined) return unknownMaintenanceDiagnostics(); // Older persisted attempts remain unknown.
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const input = value as Partial<RegionalMaintenanceDiagnostics>;
  if (!(input.phase === null || maintenancePhases.includes(input.phase!))
    || !(input.httpStatus === null || (Number.isInteger(input.httpStatus) && input.httpStatus! >= 100 && input.httpStatus! <= 599))
    || !(input.redirectStatus === null || (Number.isInteger(input.redirectStatus) && input.redirectStatus! >= 300 && input.redirectStatus! <= 399))
    || !(input.downloadBytes === null || (Number.isSafeInteger(input.downloadBytes) && input.downloadBytes! >= 0))
    || !(input.downloadComplete === null || typeof input.downloadComplete === "boolean")) return null;
  return { phase: input.phase!, httpStatus: input.httpStatus!, redirectStatus: input.redirectStatus!,
    downloadBytes: input.downloadBytes!, downloadComplete: input.downloadComplete! };
}
