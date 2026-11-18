interface StationCountryEvidence {
  countryCode: string;
  names: readonly string[];
  latitude: number;
  longitude: number;
  source: string;
}

// Generalized country polygons cannot settle these stations near borders/coasts.
// Official station pages establish the physical country. Coordinate anchors were
// checked against the 2026-11-13 Transitous inventory; Wasserbillig and Mertert also have CFL GPS.
// Malmö/Copenhagen anchors reproduce the 2026-11-16 live import receipts.
// An exact normalized name AND a location within 400 m are required. This is station
// evidence, never a rule about an operator, feed prefix, timezone, or nearby town.
const stationEvidence: readonly StationCountryEvidence[] = [
  {
    countryCode: "MC",
    names: ["Monaco-Monte-Carlo", "Gare de Monaco - Pont Sainte Dévote"],
    latitude: 43.738414, longitude: 7.419747,
    source: "https://www.ter.sncf.com/sud-provence-alpes-cote-d-azur/se-deplacer/gares/Monaco-Monte-Carlo-87756403",
  },
  {
    countryCode: "LU",
    names: ["Wasserbillig", "Wasserbillig, Gare"],
    latitude: 49.712778, longitude: 6.499167,
    source: "https://www.cfl.lu/fr-fr/network/station/gare-de-wasserbillig?tab=1000",
  },
  {
    countryCode: "LU",
    names: ["Mertert", "Mertert, Gare"],
    latitude: 49.703056, longitude: 6.478889,
    source: "https://www.cfl.lu/fr-FR/network/station/Gare-de-Mertert",
  },
  {
    countryCode: "CH",
    names: ["Buchs SG", "Buchs Bahnhof", "Buchs SG, Bahnhof"],
    latitude: 47.169727, longitude: 9.478511,
    source: "https://stadtkarte.buchs-sg.ch/map/place/jte1ox8y",
  },
  {
    countryCode: "DE",
    names: ["Freilassing", "Freilassing Bahnhof"],
    latitude: 47.836937, longitude: 12.97655,
    source: "https://www.bahnhof.de/freilassing",
  },
  {
    countryCode: "IT",
    names: ["Ventimiglia", "Ventimiglia - Stazione"],
    latitude: 43.792569, longitude: 7.610233,
    source: "https://www.ter.sncf.com/normandie/se-deplacer/gares/ventimiglia-83045013",
  },
  {
    countryCode: "SE",
    names: ["Malmö C", "Malmö Centralstation"],
    latitude: 55.609444, longitude: 13.000833,
    source: "https://www.jernhusen.se/hitta-din-station/malmo-centralstation/",
  },
  {
    countryCode: "DK",
    names: ["København H", "Koebenhavn H"],
    latitude: 55.673058, longitude: 12.565558,
    source: "https://www.dsb.dk/trafikinformation/stationer/kobenhavn-h/",
  },
];

function normalizedName(name: string): string {
  return name.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();
}

const evidenceByName = new Map(stationEvidence.flatMap((station) =>
  station.names.map((name) => [normalizedName(name), station] as const)));

export function evidencedStationCountryCode(name: string | undefined, latitude: number, longitude: number): string | undefined {
  if (!name || !Number.isFinite(latitude) || !Number.isFinite(longitude)) return undefined;
  const station = evidenceByName.get(normalizedName(name));
  if (!station) return undefined;
  const northMeters = (latitude - station.latitude) * 111_320;
  const eastMeters = (longitude - station.longitude) * 111_320 * Math.cos(station.latitude * Math.PI / 180);
  return Math.hypot(northMeters, eastMeters) <= 400 ? station.countryCode : undefined;
}
