import type { StationSnapshot } from "../domain/discovery.js";
import type { RailPlaceSnapshot } from "../domain/journey.js";
import { encodeRailPlaceId, type DecodedRailPlaceId } from "./rail-place-id.js";

export const srbijaVozAttributions = ["Srbijavoz official timetable"];
export const srbijaVozTimeZone = "Europe/Belgrade";

// Official eKarta station codes, checked 2026-11-13. Coordinates were verified
// against the corresponding operator stops in Transitous on the same date.
// TPS Novi Sad and the old Novi Sad station are different, unmapped places.
export const srbijaVozStations = [
  {
    code: 16052,
    name: "Beograd Centar-PROKOP",
    aliases: ["Beograd", "Beograd Centar", "Belgrade", "Belgrade Centre", "Belgrade Center", "Prokop", "Београд центар", "Београд", "Прокоп"],
    transitousId: "rs-Srbijavoz_7200080",
    transitousAliases: ["rs-Srbijavoz_7200080", "hu-mav_1:007216052"],
    latitude: 44.79363,
    longitude: 20.453129,
  },
  {
    code: 16807,
    name: "Petrovaradin",
    aliases: ["Petrovaradin", "Петроварадин"],
    transitousId: "rs-Srbijavoz_7216807",
    transitousAliases: ["rs-Srbijavoz_7216807"],
    latitude: 45.239754,
    longitude: 19.88864,
  },
] as const;

export type SrbijaVozStation = typeof srbijaVozStations[number];

export function srbijaVozStation(code: string | number): SrbijaVozStation | undefined {
  return srbijaVozStations.find((station) => String(station.code) === String(code));
}

export function srbijaVozStationForPlace(place: DecodedRailPlaceId): SrbijaVozStation | undefined {
  if (place.kind !== "station" || place.countryCode !== "RS") return undefined;
  if (place.provider === "srbijavoz") return srbijaVozStation(place.nativeId);
  return srbijaVozStations.find((station) =>
    (station.transitousAliases as readonly string[]).includes(place.nativeId));
}

export function srbijaVozPlace(station: SrbijaVozStation): RailPlaceSnapshot {
  return {
    id: encodeRailPlaceId({
      provider: "srbijavoz", kind: "station", nativeId: String(station.code),
      countryCode: "RS", latitude: null, longitude: null,
    }),
    kind: "station",
    displayName: station.name,
    context: srbijaVozTimeZone,
    countryCode: "RS",
    timeZoneIdentifier: srbijaVozTimeZone,
    location: { latitude: station.latitude, longitude: station.longitude },
    eligibleModes: ["longDistanceRail", "regionalRail"],
    attributions: [...srbijaVozAttributions],
  };
}

export function srbijaVozStationSnapshot(station: SrbijaVozStation): StationSnapshot {
  return {
    id: `rs:srbijavoz:${station.code}`,
    source: "srbijavoz", nativeId: String(station.code), name: station.name,
    countryCode: "RS", latitude: station.latitude, longitude: station.longitude,
    operatorHints: ["Srbijavoz"],
  };
}

export function searchSrbijaVozStations(query: string): SrbijaVozStation[] {
  const normalize = (value: string) => value.normalize("NFKD").replaceAll(/\p{M}/gu, "")
    .toLocaleLowerCase("en").replaceAll(/[^\p{L}\p{N}]+/gu, " ").trim();
  const needle = normalize(query);
  if (needle.length < 2) return [];
  return srbijaVozStations.filter((station) => [station.name, ...station.aliases]
    .some((name) => normalize(name).includes(needle)));
}
