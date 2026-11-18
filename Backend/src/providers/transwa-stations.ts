import type { StationSnapshot } from "../domain/discovery.js";

interface TranswaStation {
  name: string;
  aliases?: readonly string[];
  stopIds: readonly string[];
  latitude: number;
  longitude: number;
}

// Transwa rail stops are published in the official Transperth GTFS, but the
// upstream stop metadata currently labels them as buses. Keep this bounded
// list to the stops used by the four route_type=2 Transwa services so urban
// Transperth bus and commuter records cannot leak into mainline discovery.
const stations: readonly TranswaStation[] = [
  { name: "Armadale", stopIds: ["95000", "95001"], latitude: -32.15376, longitude: 116.01278 },
  { name: "Byford", stopIds: ["95002", "95003"], latitude: -32.216602, longitude: 116.00739 },
  { name: "Mundijong", stopIds: ["95004", "95005"], latitude: -32.294704, longitude: 115.986595 },
  { name: "Serpentine", stopIds: ["95006", "95007"], latitude: -32.363754, longitude: 115.97606 },
  { name: "North Dandalup", stopIds: ["95008", "95009"], latitude: -32.517807, longitude: 115.96862 },
  { name: "Pinjarra", stopIds: ["95010", "95011"], latitude: -32.628216, longitude: 115.87984 },
  { name: "Waroona", stopIds: ["95012", "95013"], latitude: -32.845486, longitude: 115.92023 },
  { name: "Yarloop", stopIds: ["95014", "95015"], latitude: -32.95569, longitude: 115.89959 },
  { name: "Cookernup", stopIds: ["95016", "95017"], latitude: -32.994778, longitude: 115.89306 },
  { name: "Harvey", stopIds: ["95018", "95019"], latitude: -33.079147, longitude: 115.89749 },
  { name: "Brunswick Junction", stopIds: ["95020", "95021"], latitude: -33.25729, longitude: 115.83845 },
  { name: "Bunbury", aliases: ["Bunbury Passenger Terminal"], stopIds: ["95022", "95023"], latitude: -33.34465, longitude: 115.657234 },
  { name: "East Perth", aliases: ["East Perth Terminal"], stopIds: ["95024", "95025"], latitude: -31.943974, longitude: 115.87715 },
  { name: "Midland", stopIds: ["95026", "95027"], latitude: -31.892405, longitude: 116.00321 },
  { name: "Toodyay", stopIds: ["95028", "95029"], latitude: -31.551512, longitude: 116.46521 },
  { name: "Northam", stopIds: ["95030", "95031"], latitude: -31.648771, longitude: 116.67595 },
  { name: "Meckering", stopIds: ["95032", "95033"], latitude: -31.623644, longitude: 117.01357 },
  { name: "Cunderdin", stopIds: ["95034", "95035"], latitude: -31.64592, longitude: 117.243835 },
  { name: "Tammin", stopIds: ["95036", "95037"], latitude: -31.641956, longitude: 117.48702 },
  { name: "Kellerberrin", stopIds: ["95038", "95039"], latitude: -31.633188, longitude: 117.72037 },
  { name: "Doodlakine", stopIds: ["95040", "95041"], latitude: -31.608181, longitude: 117.88189 },
  { name: "Hines Hill", stopIds: ["95042", "95043"], latitude: -31.529457, longitude: 118.08113 },
  { name: "Merredin", stopIds: ["95044", "95045"], latitude: -31.482643, longitude: 118.27798 },
  { name: "Carrabin", stopIds: ["95048", "95049"], latitude: -31.391296, longitude: 118.67046 },
  { name: "Bodallin", stopIds: ["95050", "95051"], latitude: -31.373144, longitude: 118.872025 },
  { name: "Moorine Rock", stopIds: ["95052", "95053"], latitude: -31.318712, longitude: 119.073685 },
  { name: "Southern Cross", stopIds: ["95054", "95055"], latitude: -31.214819, longitude: 119.310455 },
  { name: "Bonnie Vale", stopIds: ["95056", "95057"], latitude: -30.842342, longitude: 121.14999 },
  { name: "Kalgoorlie", stopIds: ["95058", "95059"], latitude: -30.745499, longitude: 121.46696 },
  { name: "Koolyanobbing", stopIds: ["95060", "95061"], latitude: -30.828026, longitude: 119.51329 },
  { name: "Perth", aliases: ["Perth Station"], stopIds: ["95499"], latitude: -31.951296, longitude: 115.86013 },
] as const;

const transwaRouteNames = new Set(["australind", "avonlink", "merredinlink", "prospector"]);

function normalized(value: string): string {
  return value.toLocaleLowerCase("en-AU").replace(/[^a-z0-9]+/gu, " ").trim();
}

function matches(query: string, station: TranswaStation): boolean {
  const candidates = [station.name, ...(station.aliases ?? [])].map(normalized);
  return candidates.some((candidate) => candidate.includes(query) || query.includes(candidate));
}

export function searchTranswaStations(query: string): StationSnapshot[] {
  const value = normalized(query);
  if (value.length < 2) return [];
  return stations.filter((station) => matches(value, station)).map((station) => {
    const nativeId = station.stopIds.map((id) => `au-wa-Transperth_${id}`).join("|");
    return {
      id: `eu:transitous:${nativeId}`,
      source: "transitous",
      nativeId,
      name: `${station.name} (Transwa)`,
      countryCode: "AU",
      latitude: station.latitude,
      longitude: station.longitude,
      operatorHints: ["Transwa"],
    };
  });
}

export function isTranswaRailDeparture(tripId: string, routeLongName: string | null | undefined): boolean {
  return tripId.toLowerCase().includes("_au-wa-transperth_")
    && transwaRouteNames.has(normalized(routeLongName ?? ""));
}
