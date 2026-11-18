// Transitous indexes these domestic stations in Cyrillic. These spellings name
// the same station; Novi Sad and Petrovaradin are deliberately not aliases.
const aliases = new Map<string, { searchValue: string; preferredNativeId: string }>([
  ...["beograd centar", "belgrade centre", "belgrade center", "belgrade centar", "београд центар"]
    .map((key) => [key, { searchValue: "Београд Центар", preferredNativeId: "rs-Srbijavoz_7200080" }] as const),
  ...["petrovaradin", "петроварадин"]
    .map((key) => [key, { searchValue: "Петроварадин", preferredNativeId: "rs-Srbijavoz_7216807" }] as const),
]);

export function serbianStationSearchAlias(query: string) {
  return aliases.get(query.trim().toLocaleLowerCase("en").replaceAll(/\s+/gu, " "));
}
