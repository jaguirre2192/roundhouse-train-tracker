const separator = "\u001f";
const maximumPlaceIdLength = 1_000;
const maximumNativeIdLength = 500;
const invalidMessage = "Invalid rail place ID";

export interface DecodedRailPlaceId {
  provider: "transitous" | "srbijavoz";
  kind: "city" | "station";
  nativeId: string;
  countryCode: string;
  latitude: number | null;
  longitude: number | null;
}

function invalid(): never {
  throw new Error(invalidMessage);
}

function hasWellFormedUtf16(value: string): boolean {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      if (index + 1 >= value.length) return false;
      const next = value.charCodeAt(index + 1);
      if (next < 0xdc00 || next > 0xdfff) return false;
      index += 1;
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      return false;
    }
  }
  return true;
}

function validNativeId(value: string): boolean {
  return value.length > 0
    && value.length <= maximumNativeIdLength
    && !value.includes(separator)
    && hasWellFormedUtf16(value);
}

function validCountryCode(value: string): boolean {
  return /^[A-Z]{2}$/u.test(value);
}

function validLatitude(value: number): boolean {
  return Number.isFinite(value) && value >= -90 && value <= 90;
}

function validLongitude(value: number): boolean {
  return Number.isFinite(value) && value >= -180 && value <= 180;
}

function coordinateField(value: number): string {
  return Object.is(value, -0) ? "-0" : String(value);
}

function coordinateFields(value: DecodedRailPlaceId): [string, string] {
  if (value.kind === "station") {
    if (value.latitude !== null || value.longitude !== null) invalid();
    return ["", ""];
  }
  if (value.latitude === null || value.longitude === null
    || !validLatitude(value.latitude) || !validLongitude(value.longitude)) invalid();
  return [coordinateField(value.latitude), coordinateField(value.longitude)];
}

export function encodeRailPlaceId(value: DecodedRailPlaceId): string {
  if ((value.provider !== "transitous" && value.provider !== "srbijavoz")
    || (value.kind !== "city" && value.kind !== "station")
    || !validNativeId(value.nativeId)
    || !validCountryCode(value.countryCode)) invalid();
  if (value.provider === "srbijavoz" && (value.kind !== "station" || value.countryCode !== "RS")) invalid();
  const [latitude, longitude] = coordinateFields(value);
  const payload = Buffer.from([
    value.nativeId,
    value.countryCode,
    latitude,
    longitude,
  ].join(separator), "utf8").toString("base64url");
  const result = `rail:${value.provider}:${value.kind}:${payload}`;
  if (result.length > maximumPlaceIdLength) invalid();
  return result;
}

function decodePayload(payload: string): string[] {
  if (!/^[A-Za-z0-9_-]+$/u.test(payload)) invalid();
  const bytes = Buffer.from(payload, "base64url");
  if (bytes.toString("base64url") !== payload) invalid();
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes).split(separator);
  } catch {
    return invalid();
  }
}

export function decodeRailPlaceId(value: string): DecodedRailPlaceId {
  if (typeof value !== "string" || value.length === 0 || value.length > maximumPlaceIdLength) invalid();
  const match = /^rail:(transitous|srbijavoz):(city|station):([A-Za-z0-9_-]+)$/u.exec(value);
  if (match === null) invalid();
  const provider = match[1] as DecodedRailPlaceId["provider"];
  const kind = match[2] as "city" | "station";
  const fields = decodePayload(match[3]!);
  if (fields.length !== 4) invalid();
  const [nativeId, countryCode, latitudeField, longitudeField] = fields as [string, string, string, string];
  if (!validNativeId(nativeId) || !validCountryCode(countryCode)) invalid();

  let decoded: DecodedRailPlaceId;
  if (kind === "station") {
    if (latitudeField !== "" || longitudeField !== "") invalid();
    decoded = {
      provider,
      kind,
      nativeId,
      countryCode,
      latitude: null,
      longitude: null,
    };
  } else {
    if (latitudeField === "" || longitudeField === "") invalid();
    const latitude = Number(latitudeField);
    const longitude = Number(longitudeField);
    if (!validLatitude(latitude) || !validLongitude(longitude)) invalid();
    decoded = {
      provider,
      kind,
      nativeId,
      countryCode,
      latitude,
      longitude,
    };
  }
  if (encodeRailPlaceId(decoded) !== value) invalid();
  return decoded;
}
