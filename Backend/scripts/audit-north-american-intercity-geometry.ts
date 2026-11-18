import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { NorthAmericanIntercityGTFSGeometryCatalog } from "../src/providers/north-american-intercity-gtfs-geometry.js";
import { evaluateNorthAmericanIntercityGeometryAudit } from "../src/providers/north-american-intercity-geometry-audit.js";
import {
  normalizedNorthAmericanIntercityOperator,
  type NorthAmericanIntercityGTFSGeometryData,
  type NorthAmericanIntercityOperator,
} from "../src/providers/north-american-intercity-gtfs-model.js";

interface AmtrakerStation {
  code: string;
  lat?: number | null;
  lon?: number | null;
}

interface AmtrakerTrain {
  trainID: string;
  trainNum: string;
  provider?: string | null;
  stations: { code: string }[];
}

type StationResponse = Record<string, AmtrakerStation>;
type TrainResponse = Record<string, AmtrakerTrain[]>;

interface GeneratedArtifact extends NorthAmericanIntercityGTFSGeometryData {
  feedMetadata: readonly {
    id: string;
    url: string;
    operator: NorthAmericanIntercityOperator;
    version: string;
    sha256: string;
    source: string;
    distributionApprovalReference: string | null;
  }[];
}

function asGeneratedArtifact(value: unknown): GeneratedArtifact {
  if (typeof value !== "object" || value === null) throw new Error("Generated catalog is not an object");
  const artifact = value as Partial<GeneratedArtifact>;
  if (typeof artifact.feedVersion !== "string"
    || typeof artifact.matches !== "object" || artifact.matches === null
    || typeof artifact.partialMatches !== "object" || artifact.partialMatches === null
    || typeof artifact.shapes !== "object" || artifact.shapes === null
    || !Array.isArray(artifact.feedMetadata)) {
    throw new Error("Generated catalog has an invalid schema");
  }
  const ids = artifact.feedMetadata.map((feed) => feed.id).sort();
  if (ids.join(",") !== "amtrak,brightline,sjjpa,via"
    || artifact.feedMetadata.some((feed) => !/^[a-f0-9]{64}$/u.test(feed.sha256))) {
    throw new Error("Generated catalog provenance is incomplete");
  }
  if (Object.keys(artifact.matches).length < 600
    || Object.keys(artifact.partialMatches).length < 100
    || Object.keys(artifact.shapes).length < 150
    || !Object.keys(artifact.matches).some((key) => key.startsWith("amtrak|"))
    || !Object.keys(artifact.matches).some((key) => key.startsWith("brightline|"))
    || !Object.keys(artifact.matches).some((key) => key.startsWith("via|"))) {
    throw new Error("Generated catalog failed integrity thresholds");
  }
  return artifact as GeneratedArtifact;
}

async function fetchJSON<T>(path: string): Promise<T> {
  const response = await fetch(`https://api.amtraker.com/v3/${path}`, {
    headers: { accept: "application/json", "user-agent": "TrainTrackerGeometryAudit/1.0" },
    signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) throw new Error(`Amtraker ${path} returned ${response.status}`);
  return response.json() as Promise<T>;
}

const [stations, trainsByKey] = await Promise.all([
  fetchJSON<StationResponse>("stations"),
  fetchJSON<TrainResponse>("trains"),
]);
const trains = Object.values(trainsByKey).flat();
const artifactPath = resolve(
  process.env.NORTH_AMERICAN_INTERCITY_GTFS_GENERATED_PATH ?? ".generated/north-american-intercity-gtfs-catalog.json",
);
const artifact = asGeneratedArtifact(JSON.parse(await readFile(artifactPath, "utf8")) as unknown);
const enabledOperators: readonly NorthAmericanIntercityOperator[] = ["amtrak", "brightline", "via"];
const catalog = new NorthAmericanIntercityGTFSGeometryCatalog({ data: artifact, enabledOperators });
const counts = new Map<string, { total: number; matched: number; misses: string[] }>();

for (const train of trains) {
  const operator = normalizedNorthAmericanIntercityOperator(train.provider ?? "");
  if (operator === null) continue;
  const current = counts.get(operator) ?? { total: 0, matched: 0, misses: [] };
  current.total += 1;
  const geometry = await catalog.geometryFor(
    train.provider ?? "",
    train.trainNum,
    train.stations.map((stop) => ({
      code: stop.code,
      latitude: stations[stop.code]?.lat ?? null,
      longitude: stations[stop.code]?.lon ?? null,
    })),
  );
  if (geometry === null) current.misses.push(`${train.trainID}:${train.trainNum}`);
  else current.matched += 1;
  counts.set(operator, current);
}

const summary = Object.fromEntries([...counts.entries()].sort(([left], [right]) => left.localeCompare(right)));
console.info(JSON.stringify({
  catalog: {
    feedVersion: artifact.feedVersion,
    matches: Object.keys(artifact.matches).length,
    partialMatches: Object.keys(artifact.partialMatches).length,
    shapes: Object.keys(artifact.shapes).length,
    sources: artifact.feedMetadata,
  },
  live: summary,
}, null, 2));
const audit = evaluateNorthAmericanIntercityGeometryAudit(counts, enabledOperators);
for (const warning of audit.warnings) console.info(`::warning title=Live train without route geometry::${warning}`);
for (const failure of audit.failures) console.info(`::error title=Route geometry coverage dropped::${failure}`);
if (!audit.passed) process.exitCode = 1;
