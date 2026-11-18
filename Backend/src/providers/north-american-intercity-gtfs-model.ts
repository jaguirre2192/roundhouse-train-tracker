export type NorthAmericanIntercityGTFSShape = readonly [
  encodedPolyline: string,
  pointCount: number,
  source: string,
];

export interface NorthAmericanIntercityGTFSGeometryData {
  feedVersion: string;
  matches: Readonly<Record<string, string>>;
  partialMatches: Readonly<Record<string, string>>;
  shapes: Readonly<Record<string, NorthAmericanIntercityGTFSShape>>;
}

export type NorthAmericanIntercityOperator = "amtrak" | "brightline" | "via";
const supportedNorthAmericanIntercityOperators: readonly NorthAmericanIntercityOperator[] = ["amtrak", "brightline", "via"];

export function northAmericanIntercityOperatorsFromAllowlist(value: string): NorthAmericanIntercityOperator[] {
  const requested = [...new Set(value.split(",")
    .map((operator) => operator.trim().toLowerCase())
    .filter((operator) => operator.length > 0))].sort();
  const unsupported = requested.filter(
    (operator) => !supportedNorthAmericanIntercityOperators.includes(operator as NorthAmericanIntercityOperator),
  );
  if (unsupported.length > 0) {
    throw new Error(`NORTH_AMERICAN_INTERCITY_GTFS_GEOMETRY_OPERATORS contains unsupported values: ${unsupported.join(", ")}`);
  }
  return requested as NorthAmericanIntercityOperator[];
}

export function normalizedNorthAmericanIntercityOperator(value: string): NorthAmericanIntercityOperator | null {
  const normalized = value.trim().toLowerCase();
  if (normalized.includes("brightline")) return "brightline";
  if (normalized.includes("amtrak")) return "amtrak";
  if (normalized === "via" || normalized.includes("via rail")) return "via";
  return null;
}

export function normalizedNorthAmericanIntercityTrainNumber(
  operator: NorthAmericanIntercityOperator,
  value: string,
): string {
  const normalized = value.trim().toUpperCase();
  const providerPrefix = operator === "brightline" ? "B" : operator === "via" ? "V" : null;
  const withoutProviderPrefix = providerPrefix === null
    ? normalized
    : normalized.replace(new RegExp(`^${providerPrefix}(?=\\d+$)`, "u"), "");
  return /^\d+$/u.test(withoutProviderPrefix)
    ? withoutProviderPrefix.replace(/^0+(?=\d)/u, "")
    : withoutProviderPrefix;
}

export function northAmericanIntercityGTFSPartialMatchKey(
  operator: NorthAmericanIntercityOperator,
  trainNumber: string,
): string | null {
  const normalizedTrainNumber = normalizedNorthAmericanIntercityTrainNumber(operator, trainNumber);
  return normalizedTrainNumber.length === 0 ? null : `${operator}|${normalizedTrainNumber}`;
}

export function northAmericanIntercityGTFSMatchKey(
  operator: NorthAmericanIntercityOperator,
  trainNumber: string,
  stationCodes: readonly string[],
): string | null {
  const partialKey = northAmericanIntercityGTFSPartialMatchKey(operator, trainNumber);
  const normalizedStationCodes = stationCodes.map((value) => value.trim().toUpperCase());
  if (partialKey === null
    || normalizedStationCodes.length < 2
    || normalizedStationCodes.some((value) => value.length === 0)) return null;
  return `${partialKey}|${normalizedStationCodes.join(">")}`;
}
