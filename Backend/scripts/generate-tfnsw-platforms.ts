import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { strFromU8, unzipSync } from "fflate";

function row(line: string): string[] {
  const values: string[] = [];
  let value = "";
  let quoted = false;
  for (let index = 0; index < line.length; index += 1) {
    const character = line[index]!;
    if (character === '"') {
      if (quoted && line[index + 1] === '"') {
        value += '"';
        index += 1;
      } else {
        quoted = !quoted;
      }
    } else if (character === "," && !quoted) {
      values.push(value);
      value = "";
    } else {
      value += character;
    }
  }
  values.push(value.replace(/\r$/u, ""));
  return values;
}

const archivePath = process.argv[2];
if (archivePath === undefined) throw new Error("Pass the official TfNSW nswtrains GTFS zip path");
const archive = unzipSync(new Uint8Array(await readFile(resolve(archivePath))));
const stopsFile = archive["stops.txt"];
if (stopsFile === undefined) throw new Error("The GTFS archive does not contain stops.txt");
const lines = strFromU8(stopsFile).split("\n").filter((line) => line.length > 0);
const headers = row(lines.shift() ?? "");
const index = Object.fromEntries(headers.map((header, position) => [header, position]));
const values = lines.map(row).flatMap((values): Array<[string, { parentStation: string; platform: string }]> => {
  const stopId = values[index.stop_id ?? -1]?.trim() ?? "";
  const parentStation = values[index.parent_station ?? -1]?.trim() ?? "";
  const platform = values[index.platform_code ?? -1]?.trim() ?? "";
  return stopId.length > 0 && parentStation.length > 0 && platform.length > 0
    ? [[stopId, { parentStation, platform }]]
    : [];
});
values.sort(([left], [right]) => left.localeCompare(right, "en", { numeric: true }));
const generated = `// Generated from Transport for NSW's CC BY 4.0 NSW Trains GTFS stops.txt.\n`
  + `// Regenerate with: npm run generate:tfnsw-platforms -- /path/to/nswtrains.zip\n`
  + `export const tfNSWPlatforms: Readonly<Record<string, { parentStation: string; platform: string }>> = ${JSON.stringify(Object.fromEntries(values), null, 2)};\n`;
await writeFile(new URL("../src/providers/tfnsw-platforms.generated.ts", import.meta.url), generated, "utf8");
console.log(`Generated ${values.length} TfNSW platform stop mappings.`);
