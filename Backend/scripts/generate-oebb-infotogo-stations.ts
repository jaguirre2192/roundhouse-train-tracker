import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { strFromU8, unzipSync } from "fflate";

interface GeoNetworkFeature {
  geometry?: { type?: string; coordinates?: unknown };
  properties?: {
    PLC?: number | string;
    STP_NAME?: string;
    STP_LAT?: number;
    STP_LON?: number;
  };
}

interface GeoNetwork {
  features?: GeoNetworkFeature[];
}

const archivePath = process.argv[2];
if (archivePath === undefined) throw new Error("Pass the official ÖBB GeoNetz GeoJSON zip path");
const archive = unzipSync(new Uint8Array(await readFile(resolve(archivePath))));
let networkFile = Object.entries(archive).find(([name]) => name.endsWith("/OEBB_NETWORK.json")
  || name === "OEBB_NETWORK.json")?.[1];
if (networkFile === undefined) {
  const nestedArchive = Object.entries(archive).find(([name]) => name.endsWith("/OEBB_NETWORK_GeoJSON.zip")
    || name === "OEBB_NETWORK_GeoJSON.zip")?.[1];
  if (nestedArchive !== undefined) {
    networkFile = Object.entries(unzipSync(nestedArchive)).find(([name]) => name.endsWith("/OEBB_NETWORK.json")
      || name === "OEBB_NETWORK.json")?.[1];
  }
}
if (networkFile === undefined) throw new Error("The ÖBB GeoNetz archive does not contain OEBB_NETWORK.json");
const network = JSON.parse(strFromU8(networkFile)) as GeoNetwork;
const stations = (network.features ?? []).flatMap((feature): Array<readonly [string, string, number, number]> => {
  const properties = feature.properties;
  const plc = String(properties?.PLC ?? "");
  const stationId = plc.replace(/^(\d{2})0(\d{5})$/u, "$1$2");
  const name = properties?.STP_NAME?.trim() ?? "";
  const latitude = properties?.STP_LAT;
  const longitude = properties?.STP_LON;
  if (!/^81\d{5}$/u.test(stationId) || name.length === 0
    || latitude === undefined || longitude === undefined
    || !Number.isFinite(latitude) || !Number.isFinite(longitude)) return [];
  return [[stationId, name, latitude, longitude] as const];
});
const stationIds = new Set(stations.map((station) => station[0]));
if (stationIds.size !== stations.length) throw new Error("The ÖBB GeoNetz data contains duplicate InfoToGo IDs");
if (stations.length < 500 || !stationIds.has("8101003")) {
  throw new Error("The ÖBB GeoNetz station schema did not produce a credible national InfoToGo index");
}
stations.sort((left, right) => left[0].localeCompare(right[0], "en", { numeric: true }));
const generated = `// Generated from ÖBB-Infrastruktur AG's CC BY 3.0 AT GeoNetz station data.\n`
  + `// Regenerate with: npm run generate:oebb-infotogo-stations -- /path/to/GeoNetz_12-2024.zip\n`
  + `export const oebbInfoToGoStations: ReadonlyArray<readonly [string, string, number, number]> = ${JSON.stringify(stations)};\n`;
await writeFile(new URL("../src/providers/oebb-infotogo-stations.generated.ts", import.meta.url), generated, "utf8");
console.log(`Generated ${stations.length} ÖBB InfoToGo station mappings.`);
