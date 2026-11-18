import { writeFile } from "node:fs/promises";
import { transitousAPIOrigin, transitousContact } from "../src/providers/transitous-client.js";
import { isMainlineRailMode, mainlineRailModesParameter } from "../src/providers/mainline-modes.js";
import {
  isTrackableTransitousDeparture,
  isTrackableTransitousStation,
} from "../src/providers/transitous-mainline-scope.js";

interface Target {
  countryCode: string;
  name: string;
  queries: string[];
}

interface TransitousGeocode {
  type: string;
  name: string;
  id: string;
  lat: number;
  lon: number;
  country?: string | null;
}

interface TransitousPlace {
  name: string;
  stopId?: string | null;
  scheduledArrival?: string | null;
  scheduledDeparture?: string | null;
  arrival?: string | null;
  departure?: string | null;
  scheduledTrack?: string | null;
  track?: string | null;
}

interface TransitousStopTime {
  tripId: string;
  mode: string;
  routeLongName?: string | null;
  realTime?: boolean | null;
  place: TransitousPlace;
}

interface TransitousStopTimes {
  stopTimes: TransitousStopTime[];
}

interface TransitousTrip {
  legs: Array<{
    tripId?: string | null;
    from: TransitousPlace;
    to: TransitousPlace;
    intermediateStops?: TransitousPlace[] | null;
  }>;
}

const targets: Target[] = [
  { countryCode: "AD", name: "Andorra", queries: ["Andorra la Vella"] },
  { countryCode: "AL", name: "Albania", queries: ["Tirana"] },
  { countryCode: "AM", name: "Armenia", queries: ["Yerevan"] },
  { countryCode: "AT", name: "Austria", queries: ["Wien Hauptbahnhof", "Vienna Central"] },
  { countryCode: "AZ", name: "Azerbaijan", queries: ["Baku Railway Station", "Bakı"] },
  { countryCode: "BA", name: "Bosnia and Herzegovina", queries: ["Sarajevo"] },
  { countryCode: "BE", name: "Belgium", queries: ["Bruxelles-Midi", "Brussels South"] },
  { countryCode: "BG", name: "Bulgaria", queries: ["Sofia Central"] },
  { countryCode: "BY", name: "Belarus", queries: ["Minsk Passazhirsky", "Minsk"] },
  { countryCode: "CH", name: "Switzerland", queries: ["Zürich HB", "Zurich HB"] },
  { countryCode: "CY", name: "Cyprus", queries: ["Nicosia"] },
  { countryCode: "CZ", name: "Czechia", queries: ["Praha hlavní nádraží", "Prague Central"] },
  { countryCode: "DE", name: "Germany", queries: ["Berlin Hauptbahnhof"] },
  { countryCode: "DK", name: "Denmark", queries: ["København H", "Copenhagen Central"] },
  { countryCode: "EE", name: "Estonia", queries: ["Tallinn Balti jaam", "Tallinn"] },
  { countryCode: "ES", name: "Spain", queries: ["Madrid Atocha"] },
  { countryCode: "FI", name: "Finland", queries: ["Helsinki"] },
  { countryCode: "FR", name: "France", queries: ["Paris Gare du Nord"] },
  { countryCode: "GB", name: "United Kingdom", queries: ["London Waterloo"] },
  { countryCode: "GE", name: "Georgia", queries: ["Tbilisi Central"] },
  { countryCode: "GR", name: "Greece", queries: ["Athens Railway Station", "Athens"] },
  { countryCode: "HR", name: "Croatia", queries: ["Zagreb Glavni kolodvor"] },
  { countryCode: "HU", name: "Hungary", queries: ["Budapest Keleti"] },
  { countryCode: "IE", name: "Ireland", queries: ["Dublin Connolly"] },
  { countryCode: "IS", name: "Iceland", queries: ["Reykjavík"] },
  { countryCode: "IT", name: "Italy", queries: ["Roma Termini"] },
  { countryCode: "LI", name: "Liechtenstein", queries: ["Schaan-Vaduz", "Schaan"] },
  { countryCode: "LT", name: "Lithuania", queries: ["Vilnius Railway Station", "Vilnius"] },
  { countryCode: "LU", name: "Luxembourg", queries: ["Luxembourg Gare"] },
  { countryCode: "LV", name: "Latvia", queries: ["Riga Central", "Rīga"] },
  { countryCode: "MC", name: "Monaco", queries: ["Monaco-Monte-Carlo"] },
  { countryCode: "MD", name: "Moldova", queries: ["Chișinău Railway Station", "Chisinau"] },
  { countryCode: "ME", name: "Montenegro", queries: ["Podgorica Railway Station", "Podgorica"] },
  { countryCode: "MK", name: "North Macedonia", queries: ["Skopje Railway Station", "Skopje"] },
  { countryCode: "MT", name: "Malta", queries: ["Valletta"] },
  { countryCode: "NL", name: "Netherlands", queries: ["Amsterdam Centraal"] },
  { countryCode: "NO", name: "Norway", queries: ["Oslo S"] },
  { countryCode: "PL", name: "Poland", queries: ["Warszawa Centralna"] },
  { countryCode: "PT", name: "Portugal", queries: ["Lisboa Oriente"] },
  { countryCode: "RO", name: "Romania", queries: ["București Nord", "Bucharest North"] },
  { countryCode: "RS", name: "Serbia", queries: ["Beograd Centar", "Belgrade Centre"] },
  { countryCode: "RU", name: "Russia", queries: ["Moscow Leningradsky", "Moskva"] },
  { countryCode: "SE", name: "Sweden", queries: ["Stockholm Central"] },
  { countryCode: "SI", name: "Slovenia", queries: ["Ljubljana Railway Station", "Ljubljana"] },
  { countryCode: "SK", name: "Slovakia", queries: ["Bratislava hlavná stanica"] },
  { countryCode: "SM", name: "San Marino", queries: ["San Marino"] },
  { countryCode: "TR", name: "Türkiye", queries: ["Istanbul Söğütlüçeşme", "Istanbul"] },
  { countryCode: "UA", name: "Ukraine", queries: ["Kyiv-Pasazhyrskyi", "Kyiv"] },
  { countryCode: "VA", name: "Vatican City", queries: ["Vatican City"] },
  { countryCode: "XK", name: "Kosovo", queries: ["Prishtina Railway Station", "Pristina"] },
  { countryCode: "JP", name: "Japan", queries: ["Tokyo"] },
  { countryCode: "CA", name: "Canada", queries: ["Montréal Central", "Montréal"] },
  { countryCode: "AU", name: "Australia", queries: ["Melbourne Southern Cross", "Southern Cross"] },
  { countryCode: "IN", name: "India", queries: ["New Delhi Railway Station", "New Delhi"] },
  { countryCode: "MA", name: "Morocco", queries: ["Casa-Voyageurs", "Casablanca"] },
  { countryCode: "MY", name: "Malaysia", queries: ["KL Sentral", "Kuala Lumpur"] },
  { countryCode: "TH", name: "Thailand", queries: ["Bangkok", "Krung Thep Aphiwat"] },
  { countryCode: "NZ", name: "New Zealand", queries: ["Wellington Railway Station", "Auckland"] },
  { countryCode: "AR", name: "Argentina", queries: ["Buenos Aires Retiro", "Rosario Norte"] },
  { countryCode: "BO", name: "Bolivia", queries: ["Oruro", "Villazón"] },
  { countryCode: "BR", name: "Brazil", queries: ["Belo Horizonte Central", "Parauapebas"] },
  { countryCode: "CL", name: "Chile", queries: ["Estación Central Santiago", "Rancagua"] },
  { countryCode: "CO", name: "Colombia", queries: ["Bogotá"] },
  { countryCode: "EC", name: "Ecuador", queries: ["Quito Chimbacalle"] },
  { countryCode: "GY", name: "Guyana", queries: ["Georgetown"] },
  { countryCode: "PY", name: "Paraguay", queries: ["Asunción"] },
  { countryCode: "PE", name: "Peru", queries: ["Cusco Wanchaq", "Machu Picchu"] },
  { countryCode: "SR", name: "Suriname", queries: ["Paramaribo"] },
  { countryCode: "UY", name: "Uruguay", queries: ["Montevideo"] },
  { countryCode: "VE", name: "Venezuela", queries: ["Caracas"] },
  { countryCode: "DZ", name: "Algeria", queries: ["Alger Gare"] },
  { countryCode: "AO", name: "Angola", queries: ["Luanda"] },
  { countryCode: "BJ", name: "Benin", queries: ["Cotonou"] },
  { countryCode: "BW", name: "Botswana", queries: ["Gaborone"] },
  { countryCode: "BF", name: "Burkina Faso", queries: ["Ouagadougou"] },
  { countryCode: "BI", name: "Burundi", queries: ["Bujumbura"] },
  { countryCode: "CV", name: "Cabo Verde", queries: ["Praia"] },
  { countryCode: "CM", name: "Cameroon", queries: ["Yaoundé"] },
  { countryCode: "CF", name: "Central African Republic", queries: ["Bangui"] },
  { countryCode: "TD", name: "Chad", queries: ["N'Djamena"] },
  { countryCode: "KM", name: "Comoros", queries: ["Moroni"] },
  { countryCode: "CD", name: "Democratic Republic of the Congo", queries: ["Kinshasa Central"] },
  { countryCode: "CG", name: "Republic of the Congo", queries: ["Brazzaville"] },
  { countryCode: "CI", name: "Côte d'Ivoire", queries: ["Abidjan"] },
  { countryCode: "DJ", name: "Djibouti", queries: ["Nagad"] },
  { countryCode: "EG", name: "Egypt", queries: ["Cairo Ramses"] },
  { countryCode: "GQ", name: "Equatorial Guinea", queries: ["Malabo"] },
  { countryCode: "ER", name: "Eritrea", queries: ["Asmara"] },
  { countryCode: "SZ", name: "Eswatini", queries: ["Mbabane"] },
  { countryCode: "ET", name: "Ethiopia", queries: ["Addis Ababa Lebu"] },
  { countryCode: "GA", name: "Gabon", queries: ["Owendo", "Libreville"] },
  { countryCode: "GM", name: "Gambia", queries: ["Banjul"] },
  { countryCode: "GH", name: "Ghana", queries: ["Accra"] },
  { countryCode: "GN", name: "Guinea", queries: ["Conakry"] },
  { countryCode: "GW", name: "Guinea-Bissau", queries: ["Bissau"] },
  { countryCode: "KE", name: "Kenya", queries: ["Nairobi Terminus"] },
  { countryCode: "LS", name: "Lesotho", queries: ["Maseru"] },
  { countryCode: "LR", name: "Liberia", queries: ["Monrovia"] },
  { countryCode: "LY", name: "Libya", queries: ["Tripoli"] },
  { countryCode: "MG", name: "Madagascar", queries: ["Antananarivo Soarano"] },
  { countryCode: "MW", name: "Malawi", queries: ["Blantyre"] },
  { countryCode: "ML", name: "Mali", queries: ["Bamako"] },
  { countryCode: "MR", name: "Mauritania", queries: ["Nouadhibou"] },
  { countryCode: "MU", name: "Mauritius", queries: ["Port Louis"] },
  { countryCode: "MZ", name: "Mozambique", queries: ["Maputo"] },
  { countryCode: "NA", name: "Namibia", queries: ["Windhoek"] },
  { countryCode: "NE", name: "Niger", queries: ["Niamey"] },
  { countryCode: "NG", name: "Nigeria", queries: ["Abuja Idu", "Lagos Mobolaji Johnson"] },
  { countryCode: "RW", name: "Rwanda", queries: ["Kigali"] },
  { countryCode: "ST", name: "São Tomé and Príncipe", queries: ["São Tomé"] },
  { countryCode: "SN", name: "Senegal", queries: ["Dakar"] },
  { countryCode: "SC", name: "Seychelles", queries: ["Victoria"] },
  { countryCode: "SL", name: "Sierra Leone", queries: ["Freetown"] },
  { countryCode: "SO", name: "Somalia", queries: ["Mogadishu"] },
  { countryCode: "ZA", name: "South Africa", queries: ["Johannesburg Park Station", "Cape Town"] },
  { countryCode: "SS", name: "South Sudan", queries: ["Juba"] },
  { countryCode: "SD", name: "Sudan", queries: ["Khartoum"] },
  { countryCode: "TZ", name: "Tanzania", queries: ["Dar es Salaam SGR"] },
  { countryCode: "TG", name: "Togo", queries: ["Lomé"] },
  { countryCode: "TN", name: "Tunisia", queries: ["Tunis Ville"] },
  { countryCode: "UG", name: "Uganda", queries: ["Kampala"] },
  { countryCode: "ZM", name: "Zambia", queries: ["Lusaka"] },
  { countryCode: "ZW", name: "Zimbabwe", queries: ["Harare"] },
];

const baseUrl = transitousAPIOrigin;
const requestHeaders = {
  accept: "application/json",
  "user-agent": `Roundhouse-CoverageAudit/0.2 (+${transitousContact})`,
};

function country(value: TransitousGeocode): string {
  return value.country?.toUpperCase() ?? value.id.slice(0, 2).toUpperCase();
}

async function json<Response>(url: URL): Promise<Response> {
  const response = await fetch(url, { headers: requestHeaders, signal: AbortSignal.timeout(12_000) });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json() as Promise<Response>;
}

async function findStation(target: Target): Promise<TransitousGeocode | null> {
  for (const query of target.queries) {
    const url = new URL("/api/v1/geocode", baseUrl);
    url.search = new URLSearchParams({
      text: query,
      type: "STOP",
      mode: mainlineRailModesParameter,
      language: "en",
      numResults: "20",
    }).toString();
    const values = await json<TransitousGeocode[]>(url);
    const match = values.find((value) =>
      value.type === "STOP"
      && country(value) === target.countryCode
      && isTrackableTransitousStation(value)
    );
    if (match !== undefined) return match;
  }
  return null;
}

function distinctPlaces(trip: TransitousTrip): TransitousPlace[] {
  const places: TransitousPlace[] = [];
  for (const leg of trip.legs.filter((value) => value.tripId !== null && value.tripId !== undefined)) {
    for (const place of [leg.from, ...(leg.intermediateStops ?? []), leg.to]) {
      const previous = places.at(-1);
      if (
        previous?.stopId === place.stopId
        && previous?.scheduledArrival === place.scheduledArrival
        && previous?.scheduledDeparture === place.scheduledDeparture
      ) continue;
      places.push(place);
    }
  }
  return places;
}

async function audit(target: Target): Promise<Record<string, unknown>> {
  try {
    const station = await findStation(target);
    if (station === null) return { ...target, level: "unavailable" };

    const boardUrl = new URL("/api/v6/stoptimes", baseUrl);
    boardUrl.search = new URLSearchParams({
      stopId: station.id,
      time: new Date().toISOString(),
      arriveBy: "false",
      mode: mainlineRailModesParameter,
      n: "10",
      language: "en",
      withAlerts: "true",
    }).toString();
    const board = await json<TransitousStopTimes>(boardUrl);
    const mainlineBoard = board.stopTimes.filter((value) =>
      isMainlineRailMode(value.mode) && isTrackableTransitousDeparture(value)
    );
    const boardEntry = mainlineBoard[0];
    if (boardEntry === undefined) {
      return { ...target, level: "station", station: { id: station.id, name: station.name } };
    }

    const tripUrl = new URL("/api/v6/trip", baseUrl);
    tripUrl.search = new URLSearchParams({
      tripId: boardEntry.tripId,
      detailedLegs: "false",
      joinInterlinedLegs: "false",
      language: "en",
    }).toString();
    const trip = await json<TransitousTrip>(tripUrl);
    const places = distinctPlaces(trip);
    const boardHasRealtime = mainlineBoard.some((value) => value.realTime === true);
    const boardHasPlatform = mainlineBoard.some((value) =>
      Boolean(value.place.track?.trim() || value.place.scheduledTrack?.trim())
    );
    const tripHasRealtime = places.some((place) =>
      (place.arrival !== null && place.arrival !== undefined && place.arrival !== place.scheduledArrival)
      || (place.departure !== null && place.departure !== undefined && place.departure !== place.scheduledDeparture)
    );
    const tripHasPlatform = places.some((place) => Boolean(place.track?.trim() || place.scheduledTrack?.trim()));
    return {
      ...target,
      level: places.length > 1 ? "trip" : "board",
      station: { id: station.id, name: station.name },
      boardEntries: mainlineBoard.length,
      tripStops: places.length,
      realtimeObserved: boardHasRealtime || tripHasRealtime,
      platformObserved: boardHasPlatform || tripHasPlatform,
      sampledTripId: boardEntry.tripId,
    };
  } catch (error) {
    return { ...target, level: "error", error: error instanceof Error ? error.message : String(error) };
  }
}

const countryArgument = process.argv.find((value) => value.startsWith("--countries="))?.split("=")[1];
const selectedCodes = countryArgument === undefined ? null : new Set(countryArgument.split(",").map((value) => value.toUpperCase()));
const selectedTargets = selectedCodes === null ? targets : targets.filter((target) => selectedCodes.has(target.countryCode));
const results: Record<string, unknown>[] = [];

for (let index = 0; index < selectedTargets.length; index += 3) {
  results.push(...await Promise.all(selectedTargets.slice(index, index + 3).map(audit)));
  if (index + 3 < selectedTargets.length) await new Promise((resolve) => setTimeout(resolve, 250));
}

const report = {
  generatedAt: new Date().toISOString(),
  upstream: baseUrl,
  methodology: "Representative mainline passenger-rail station search followed by a live departure board and first-trip fetch; metro, subway, tram, light rail, and city people movers excluded.",
  results,
};
const output = `${JSON.stringify(report, null, 2)}\n`;
const outputPath = process.argv.find((value) => value.startsWith("--output="))?.split("=")[1];
if (outputPath === undefined) process.stdout.write(output);
else await writeFile(outputPath, output, "utf8");
