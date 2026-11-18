import type { DecodedRailPlaceId } from "./rail-place-id.js";
import { serbianStationSearchAlias } from "./serbian-station-aliases.js";

export interface TransitousSearchAlias {
  searchValue: string;
  preferredNativeId: string | undefined;
}

const placeAliases = new Map<string, TransitousSearchAlias>();
const legacyCityStationAliases = new Map([
  ["US:node/[158368533]", "us-Amtrak_WAS"],
  ["US:node/[61785451]", "us-Amtrak_NYP"],
]);
const railwayStationAliases = new Map([
  // The geocoder selects Oriente's coach node; CP trips board at this rail node.
  ["PT:eu-blablacar-bus_ALE", {
    nativeId: "pt-Comboios-de-Portugal(CP)_94_31039",
    latitude: 38.767757,
    longitude: -9.099094,
  }],
  // These foreign-feed copies of Bratislava hlavná stanica route through an
  // artificial access walk to the same station's domestic ŽSR boarding node.
  // Verified against Transitous plans and ŽSR line 120 on 2026-11-13.
  ...[
    "ch-opentransportdataswiss27_Parent5613206",
    "at-Railway-Current-Reference-Data-2026_Psk:56:1",
    "hu-mav_1:005613206",
  ].map((nativeId): [string, { nativeId: string; latitude: number; longitude: number }] => [
    `SK:${nativeId}`,
    { nativeId: "sk-zsr_5613206", latitude: 48.159843, longitude: 17.10638 },
  ]),
]);

function addAliases(
  keys: string[],
  searchValue: string,
  preferredNativeId?: string,
): void {
  for (const key of keys) placeAliases.set(key, { searchValue, preferredNativeId });
}

addAliases(["dc", "d c", "washington dc", "washington d c", "was"], "Washington Union Station");
addAliases([
  "aeroport charles de gaulle 2 tgv", "aeroport paris roissy charles de gaulle cdg t2",
  "roissy airport cdg 2", "aeroport cdg 2 tgv", "aeroport paris cdg tgv",
], "Charles de Gaulle");
addAliases(["new york", "ny", "nyc", "new york city", "nyp", "new york penn station"], "New York Penn", "us-Amtrak_NYP");
addAliases(["boston south station", "south station", "bos"], "Boston", "us-Amtrak_BOS");
addAliases(["philly", "phila", "phl", "30th street", "30th street station",
  "philadelphia 30th street", "william h gray iii 30th street station"], "Philadelphia", "us-Amtrak_PHL");
addAliases(["bal"], "Baltimore", "us-Amtrak_BAL");
addAliases(["bwi", "bwi rail station", "bwi marshall rail station"], "BWI Rail Station", "us-Amtrak_BWI");
addAliases(["nhv", "new haven union station"], "New Haven", "us-Amtrak_NHV");
addAliases(["pvd", "providence station"], "Providence", "us-Amtrak_PVD");
addAliases(["nwk", "newark penn station"], "Newark", "us-Amtrak_NWK");
addAliases(["rvr", "richmond va", "richmond virginia", "richmond staples mill road",
  "richmond staples mill road station"], "Richmond Staples Mill Road", "us-Amtrak_RVR");
addAliases(["alx", "alexandria union station"], "Alexandria", "us-Amtrak_ALX");
addAliases(["wil", "wilmington de", "wilmington delaware", "wilmington station"], "Wilmington", "us-Amtrak_WIL");
addAliases(["chi", "chicago union station"], "Chicago");
addAliases(["la", "l a", "lax", "los angeles union station"], "Los Angeles", "us-Amtrak_LAX");
addAliases(["sea", "seattle king street station", "king street station"], "Seattle", "us-Amtrak_SEA");
addAliases(["pdx", "portland or", "portland oregon", "portland union station oregon"], "Portland", "us-Amtrak_PDX");
addAliases(["por", "portland me", "portland maine", "portland union station maine"], "Portland", "us-Amtrak_POR");
addAliases(["sac", "sacramento valley station"], "Sacramento", "us-Amtrak_SAC");
addAliases(["san", "san diego santa fe depot", "santa fe depot"], "San Diego", "us-Amtrak_SAN");
addAliases(["emy", "emeryville station"], "Emeryville", "us-Amtrak_EMY");
addAliases(["okj", "oakland jack london square", "jack london square"], "Oakland", "us-Amtrak_OKJ");
addAliases(["orl", "orlando amtrak", "orlando station"], "Orlando", "us-Amtrak_ORL");
addAliases(["mia", "miami amtrak", "miami amtrak station"], "Miami Amtrak Station", "us-Amtrak_MIA");
addAliases(["tpa", "tampa union station"], "Tampa", "us-Amtrak_TPA");
addAliases(["stl", "saint louis", "st louis gateway station", "st louis gateway transportation center"], "St Louis", "us-Amtrak_STL");
addAliases(["kcy", "kansas city union station"], "Kansas City", "us-Amtrak_KCY");
addAliases(["new orleans", "nol", "new orleans union passenger terminal"], "New Orleans Union Passenger Terminal", "us-Amtrak_NOL");

function aliasKey(value: string): string {
  return value.normalize("NFKD")
    .replaceAll(/\p{M}/gu, "")
    .toLocaleLowerCase("en")
    .replaceAll(/[^\p{L}\p{N}]+/gu, " ")
    .trim();
}

export function transitousSearchAlias(query: string): TransitousSearchAlias {
  const value = query.trim();
  return serbianStationSearchAlias(value)
    ?? placeAliases.get(aliasKey(value)) ?? { searchValue: value, preferredNativeId: undefined };
}

export function transitousRailwayStationAlias(nativeId: string, countryCode: string) {
  return railwayStationAliases.get(`${countryCode}:${nativeId}`);
}

export function transitousJourneyEndpointAlias(place: DecodedRailPlaceId): DecodedRailPlaceId {
  if (place.kind === "station") {
    const alias = transitousRailwayStationAlias(place.nativeId, place.countryCode);
    return alias === undefined ? place : { ...place, nativeId: alias.nativeId };
  }
  if (place.kind !== "city") return place;
  const nativeId = legacyCityStationAliases.get(`${place.countryCode}:${place.nativeId}`);
  if (nativeId === undefined) return place;
  return {
    ...place,
    kind: "station",
    nativeId,
    latitude: null,
    longitude: null,
  };
}
