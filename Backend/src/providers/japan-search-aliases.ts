import { serbianStationSearchAlias } from "./serbian-station-aliases.js";

const stationAliases = new Map<string, string>([
  ["montreal central", "Montréal"],
  ["montreal gare centrale", "Montréal"],
  ["southern cross", "Melbourne Southern Cross"],
  ["bangkok aphiwat", "Krung Thep Aphiwat"],
  ["krung thep aphiwat", "Bangkok"],
  ["new delhi", "New Delhi Railway Station"],
  ["casablanca voyageurs", "Casa-Voyageurs"],
  ["kuala lumpur sentral", "KL Sentral"],
  ["tel aviv central", "תל אביב מרכז"],
  ["tel aviv savidor", "תל אביב מרכז"],
  ["tel aviv savidor center", "תל אביב מרכז"],
  ["haifa center", "חיפה מרכז"],
  ["haifa center hashmona", "חיפה מרכז"],
  ["nahariya", "נהריה"],
  ["ben gurion airport", "נתבג"],
  ["ben gurion airport railway", "נתבג"],
  ["tokyo", "Tokyo"],
  ["shinjuku", "Shinjuku"],
  ["shibuya", "Shibuya"],
  ["shinagawa", "Shinagawa"],
  ["ueno", "Ueno"],
  ["ikebukuro", "Ikebukuro"],
  ["yokohama", "Yokohama"],
  ["kawasaki", "Kawasaki"],
  ["musashi kosugi", "Musashi-kosugi"],
  ["omiya", "Ōmiya"],
  ["chiba", "Chiba"],
  ["funabashi", "Funabashi"],
  ["tachikawa", "Tachikawa"],
  ["hachioji", "Hachiōji"],
  ["machida", "Machida"],
  ["kamakura", "Kamakura"],
  ["ofuna", "Ōfuna"],
  ["odawara", "Odawara"],
  ["atami", "Atami"],
]);

function aliasKey(value: string): string {
  return value
    .normalize("NFKD")
    .replace(/\p{Diacritic}/gu, "")
    .replace(/[-_]+/gu, " ")
    .replace(/\s+station$/iu, "")
    .replace(/\s+/gu, " ")
    .trim()
    .toLowerCase();
}

export function internationalSearchQueries(query: string): string[] {
  const value = query.trim();
  const alias = serbianStationSearchAlias(value)?.searchValue ?? stationAliases.get(aliasKey(value));
  return alias === undefined || alias === value ? [value] : [alias, value];
}
