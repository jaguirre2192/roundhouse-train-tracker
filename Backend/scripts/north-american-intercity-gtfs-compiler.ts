import { createHash } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { strFromU8, unzipSync } from "fflate";
import {
  northAmericanIntercityGTFSMatchKey,
  northAmericanIntercityGTFSPartialMatchKey,
  type NorthAmericanIntercityGTFSGeometryData,
  type NorthAmericanIntercityOperator,
} from "../src/providers/north-american-intercity-gtfs-model.js";
import { encodePolyline5 } from "../src/providers/encoded-polyline.js";

const officialFeeds = [
  {
    id: "amtrak",
    url: "https://content.amtrak.com/content/gtfs/GTFS.zip",
    agencyNames: ["amtrak"],
    operator: "amtrak",
    shapeIDPrefix: "amtrak:",
    source: "Amtrak GTFS",
    distributionApprovalReference: null,
  },
  {
    id: "brightline",
    url: "https://feed.gobrightline.com/bl_gtfs.zip",
    agencyNames: ["brightline"],
    operator: "brightline",
    shapeIDPrefix: "brightline:",
    source: "Brightline GTFS",
    distributionApprovalReference: null,
  },
  {
    id: "sjjpa",
    url: "https://d34tiw64n5z4oh.cloudfront.net/wp-content/uploads/GRGTFS.zip",
    agencyNames: ["gold runner"],
    operator: "amtrak",
    shapeIDPrefix: "sjjpa:",
    source: "SJJPA GTFS",
    distributionApprovalReference: null,
  },
  {
    id: "via",
    url: "https://www.viarail.ca/sites/all/files/gtfs/viarail.zip",
    agencyNames: ["via rail"],
    operator: "via",
    shapeIDPrefix: "via:",
    source: "VIA Rail GTFS",
    distributionApprovalReference: "https://www.viarail.ca/en/developer-resources#open-government-licence-canada-2.0",
  },
] as const;
const requiredFiles = [
  "agency.txt",
  "routes.txt",
  "trips.txt",
  "stop_times.txt",
  "shapes.txt",
] as const;
const optionalFiles = ["feed_info.txt"] as const;

type RequiredFile = typeof requiredFiles[number];

interface GTFSArchiveFiles {
  agency: string;
  feedInfo: string | null;
  routes: string;
  trips: string;
  stopTimes: string;
  shapes: string;
}

interface TripShape {
  trainNumber: string;
  shapeID: string;
}

interface StopReference {
  sequence: number;
  stationCode: string;
}

interface ShapePoint {
  sequence: number;
  latitude: number;
  longitude: number;
}

export interface NorthAmericanIntercityGTFSCompileOptions {
  agencyNames?: readonly string[];
  operator?: NorthAmericanIntercityOperator;
  shapeIDPrefix?: string;
  source?: string;
  feedVersionFallback?: string;
}

export interface GTFSFeedMetadata {
  id: string;
  url: string;
  operator: NorthAmericanIntercityOperator;
  version: string;
  sha256: string;
  source: string;
  distributionApprovalReference: string | null;
}

export interface GeneratedNorthAmericanIntercityGTFSArtifact extends NorthAmericanIntercityGTFSGeometryData {
  feedMetadata: readonly GTFSFeedMetadata[];
}

function basename(path: string): string {
  return path.split("/").at(-1) ?? path;
}

function selectedArchiveFiles(archive: Uint8Array): GTFSArchiveFiles {
  const selected = new Set<string>([...requiredFiles, ...optionalFiles]);
  const files = unzipSync(archive, {
    filter: (file) => selected.has(basename(file.name)),
  });
  const value = new Map<string, string>();
  for (const [path, bytes] of Object.entries(files)) {
    value.set(basename(path), strFromU8(bytes));
  }
  for (const required of requiredFiles) {
    if (!value.has(required)) throw new Error(`Amtrak GTFS is missing ${required}`);
  }
  return {
    agency: value.get("agency.txt")!,
    feedInfo: value.get("feed_info.txt") ?? null,
    routes: value.get("routes.txt")!,
    trips: value.get("trips.txt")!,
    stopTimes: value.get("stop_times.txt")!,
    shapes: value.get("shapes.txt")!,
  };
}

function forEachCSVRow(text: string, visit: (row: string[]) => void): void {
  let row: string[] = [];
  let field = "";
  let quoted = false;
  for (let index = 0; index <= text.length; index += 1) {
    const character = index === text.length ? "\n" : text[index]!;
    if (quoted) {
      if (character === "\"") {
        if (text[index + 1] === "\"") {
          field += "\"";
          index += 1;
        } else {
          quoted = false;
        }
      } else {
        field += character;
      }
      continue;
    }
    if (character === "\"" && field.length === 0) {
      quoted = true;
    } else if (character === ",") {
      row.push(field);
      field = "";
    } else if (character === "\n") {
      row.push(field.endsWith("\r") ? field.slice(0, -1) : field);
      if (row.some((value) => value.length > 0)) visit(row);
      row = [];
      field = "";
    } else {
      field += character;
    }
  }
}

function visitRecords(
  text: string,
  visit: (record: Readonly<Record<string, string>>) => void,
): void {
  let header: string[] | null = null;
  forEachCSVRow(text, (row) => {
    if (header === null) {
      header = row;
      return;
    }
    const record: Record<string, string> = {};
    for (let index = 0; index < header.length; index += 1) {
      record[header[index]!] = row[index] ?? "";
    }
    visit(record);
  });
}

function sortedRecord<T>(entries: Iterable<readonly [string, T]>): Record<string, T> {
  return Object.fromEntries([...entries].sort(([left], [right]) => left.localeCompare(right)));
}

export function compileNorthAmericanIntercityGTFSArchive(
  archive: Uint8Array,
  options: NorthAmericanIntercityGTFSCompileOptions = {},
): NorthAmericanIntercityGTFSGeometryData {
  const files = selectedArchiveFiles(archive);
  const acceptedAgencyNames = new Set(
    (options.agencyNames ?? ["amtrak"]).map((value) => value.trim().toLowerCase()),
  );
  const shapeIDPrefix = options.shapeIDPrefix ?? "";
  const source = options.source ?? "Amtrak GTFS";
  const operator = options.operator ?? "amtrak";
  let feedVersion = options.feedVersionFallback ?? "unknown";
  if (files.feedInfo !== null) {
    visitRecords(files.feedInfo, (record) => {
      if (record.feed_version?.trim()) {
        feedVersion = record.feed_version.trim();
        return;
      }
      const start = record.feed_start_date?.trim() ?? "";
      const end = record.feed_end_date?.trim() ?? "";
      if (start.length > 0 && end.length > 0) feedVersion = `${start}-${end}`;
    });
  }

  const amtrakAgencyIDs = new Set<string>();
  visitRecords(files.agency, (record) => {
    if (acceptedAgencyNames.has(record.agency_name?.trim().toLowerCase() ?? "")
      && record.agency_id?.trim()) {
      amtrakAgencyIDs.add(record.agency_id.trim());
    }
  });
  if (amtrakAgencyIDs.size === 0) throw new Error("Rail GTFS contains no accepted agency");

  const railRouteIDs = new Set<string>();
  visitRecords(files.routes, (record) => {
    if (record.route_id?.trim()
      && record.route_type?.trim() === "2"
      && amtrakAgencyIDs.has(record.agency_id?.trim() ?? "")) {
      railRouteIDs.add(record.route_id.trim());
    }
  });

  const trips = new Map<string, TripShape>();
  visitRecords(files.trips, (record) => {
    const tripID = record.trip_id?.trim() ?? "";
    const trainNumber = record.trip_short_name?.trim() ?? "";
    const shapeID = record.shape_id?.trim() ?? "";
    if (tripID.length > 0 && trainNumber.length > 0 && shapeID.length > 0
      && railRouteIDs.has(record.route_id?.trim() ?? "")) {
      trips.set(tripID, { trainNumber, shapeID: `${shapeIDPrefix}${shapeID}` });
    }
  });

  const stopsByTrip = new Map<string, StopReference[]>();
  visitRecords(files.stopTimes, (record) => {
    const tripID = record.trip_id?.trim() ?? "";
    if (!trips.has(tripID)) return;
    const sequence = Number(record.stop_sequence);
    const stationCode = record.stop_id?.trim() ?? "";
    if (!Number.isInteger(sequence) || sequence < 0 || stationCode.length === 0) return;
    const stops = stopsByTrip.get(tripID) ?? [];
    stops.push({ sequence, stationCode });
    stopsByTrip.set(tripID, stops);
  });

  const matches = new Map<string, string>();
  const ambiguousMatches = new Set<string>();
  for (const [tripID, trip] of trips) {
    const stationCodes = (stopsByTrip.get(tripID) ?? [])
      .sort((left, right) => left.sequence - right.sequence)
      .map((stop) => stop.stationCode);
    const key = northAmericanIntercityGTFSMatchKey(operator, trip.trainNumber, stationCodes);
    if (key === null) continue;
    const existing = matches.get(key);
    if (existing !== undefined && existing !== trip.shapeID) ambiguousMatches.add(key);
    else matches.set(key, trip.shapeID);
  }
  for (const key of ambiguousMatches) matches.delete(key);

  const partialShapeIDs = new Map<string, Set<string>>();
  for (const trip of trips.values()) {
    const key = northAmericanIntercityGTFSPartialMatchKey(operator, trip.trainNumber);
    if (key === null) continue;
    const shapeIDs = partialShapeIDs.get(key) ?? new Set<string>();
    shapeIDs.add(trip.shapeID);
    partialShapeIDs.set(key, shapeIDs);
  }
  const requestedShapeIDs = new Set([
    ...matches.values(),
    ...[...partialShapeIDs.values()].flatMap((shapeIDs) => [...shapeIDs]),
  ]);
  const pointsByShape = new Map<string, ShapePoint[]>();
  const invalidShapeIDs = new Set<string>();
  visitRecords(files.shapes, (record) => {
    const shapeID = `${shapeIDPrefix}${record.shape_id?.trim() ?? ""}`;
    if (!requestedShapeIDs.has(shapeID)) return;
    const point: ShapePoint = {
      sequence: Number(record.shape_pt_sequence),
      latitude: Number(record.shape_pt_lat),
      longitude: Number(record.shape_pt_lon),
    };
    if (!Number.isInteger(point.sequence)
      || !Number.isFinite(point.latitude) || point.latitude < -90 || point.latitude > 90
      || !Number.isFinite(point.longitude) || point.longitude < -180 || point.longitude > 180) {
      invalidShapeIDs.add(shapeID);
      return;
    }
    const points = pointsByShape.get(shapeID) ?? [];
    points.push(point);
    pointsByShape.set(shapeID, points);
  });

  const shapes = new Map<string, readonly [string, number, string]>();
  for (const [shapeID, points] of pointsByShape) {
    points.sort((left, right) => left.sequence - right.sequence);
    const repeatedSequence = points.some((point, index) => index > 0 && point.sequence === points[index - 1]!.sequence);
    if (invalidShapeIDs.has(shapeID) || repeatedSequence || points.length < 2 || points.length > 100_000) continue;
    shapes.set(shapeID, [encodePolyline5(points), points.length, source]);
  }
  for (const [key, shapeID] of matches) {
    if (!shapes.has(shapeID)) matches.delete(key);
  }
  const partialMatches = new Map<string, string>();
  for (const [key, shapeIDs] of partialShapeIDs) {
    const uniqueGeometry = new Map<string, string>();
    for (const shapeID of [...shapeIDs].sort()) {
      const shape = shapes.get(shapeID);
      const geometryKey = shape === undefined ? null : JSON.stringify(shape);
      if (geometryKey !== null && !uniqueGeometry.has(geometryKey)) {
        uniqueGeometry.set(geometryKey, shapeID);
      }
    }
    if (uniqueGeometry.size !== 1) continue;
    const shapeID = uniqueGeometry.values().next().value as string | undefined;
    if (shapeID !== undefined) partialMatches.set(key, shapeID);
  }
  const usedShapeIDs = new Set([...matches.values(), ...partialMatches.values()]);
  for (const shapeID of shapes.keys()) {
    if (!usedShapeIDs.has(shapeID)) shapes.delete(shapeID);
  }

  return {
    feedVersion,
    matches: sortedRecord(matches),
    partialMatches: sortedRecord(partialMatches),
    shapes: sortedRecord(shapes),
  };
}

export function mergeNorthAmericanIntercityGTFSData(
  sources: readonly { id: string; data: NorthAmericanIntercityGTFSGeometryData }[],
): NorthAmericanIntercityGTFSGeometryData {
  const matches = new Map<string, string>();
  const ambiguousMatches = new Set<string>();
  const partialMatches = new Map<string, string>();
  const ambiguousPartialMatches = new Set<string>();
  const shapes = new Map<string, NorthAmericanIntercityGTFSGeometryData["shapes"][string]>();
  for (const source of sources) {
    for (const [shapeID, shape] of Object.entries(source.data.shapes)) shapes.set(shapeID, shape);
    for (const [key, shapeID] of Object.entries(source.data.matches)) {
      const existing = matches.get(key);
      if (existing !== undefined && existing !== shapeID) ambiguousMatches.add(key);
      else matches.set(key, shapeID);
    }
    for (const [key, shapeID] of Object.entries(source.data.partialMatches)) {
      const existing = partialMatches.get(key);
      if (existing !== undefined && existing !== shapeID) ambiguousPartialMatches.add(key);
      else partialMatches.set(key, shapeID);
    }
  }
  for (const key of ambiguousMatches) matches.delete(key);
  for (const key of ambiguousPartialMatches) partialMatches.delete(key);
  const usedShapeIDs = new Set([...matches.values(), ...partialMatches.values()]);
  for (const shapeID of shapes.keys()) {
    if (!usedShapeIDs.has(shapeID)) shapes.delete(shapeID);
  }
  return {
    feedVersion: sources.map((source) => `${source.id}:${source.data.feedVersion}`).join(";"),
    matches: sortedRecord(matches),
    partialMatches: sortedRecord(partialMatches),
    shapes: sortedRecord(shapes),
  };
}

export function renderNorthAmericanIntercityGTFSModule(
  data: NorthAmericanIntercityGTFSGeometryData,
  metadata: readonly GTFSFeedMetadata[],
  approvalReferences: Readonly<Partial<Record<NorthAmericanIntercityOperator, string>>>,
): string {
  const approvalEntries = Object.entries(approvalReferences).flatMap(
    ([operator, reference]): [string, string][] => {
      const normalized = reference?.trim() ?? "";
      return normalized.length === 0 ? [] : [[operator, normalized]];
    },
  );
  const approvals: Record<string, string> = Object.fromEntries(approvalEntries);
  if (Object.keys(approvals).length === 0) {
    throw new Error("At least one distribution approval reference is required");
  }
  const unapprovedKeys = [...Object.keys(data.matches), ...Object.keys(data.partialMatches)]
    .filter((key) => approvals[key.split("|", 1)[0]!] === undefined);
  if (unapprovedKeys.length > 0) {
    throw new Error(`Shippable catalog contains unapproved operator data: ${unapprovedKeys[0]}`);
  }
  const lines = [
    "// Generated by npm run promote:north-american-intercity-gtfs-shapes (scripts/north-american-intercity-gtfs-compiler.ts).",
    "// Do not edit by hand. Distribution approval, source URLs, and archive hashes are recorded below.",
    "",
    `export const northAmericanIntercityGTFSDistributionApprovalReferences: Readonly<Record<string, string>> = ${JSON.stringify(approvals, null, 2)};`,
    `export const northAmericanIntercityGTFSFeedVersion = ${JSON.stringify(data.feedVersion)};`,
    `export const northAmericanIntercityGTFSFeedMetadata = ${JSON.stringify(metadata, null, 2)} as const;`,
    "export const northAmericanIntercityGTFSMatches: Record<string, string> = {",
    ...Object.entries(data.matches).map(([key, shapeID]) => `  ${JSON.stringify(key)}: ${JSON.stringify(shapeID)},`),
    "};",
    "export const northAmericanIntercityGTFSPartialMatches: Record<string, string> = {",
    ...Object.entries(data.partialMatches).map(([key, shapeID]) => `  ${JSON.stringify(key)}: ${JSON.stringify(shapeID)},`),
    "};",
    "export const northAmericanIntercityGTFSShapes: Record<string, readonly [string, number, string]> = {",
    ...Object.entries(data.shapes).map(([shapeID, shape]) => `  ${JSON.stringify(shapeID)}: [${JSON.stringify(shape[0])}, ${shape[1]}, ${JSON.stringify(shape[2])}],`),
    "};",
    "",
  ];
  return lines.join("\n");
}

async function generate(): Promise<void> {
  const sources = await Promise.all(officialFeeds.map(async (feed) => {
    const response = await fetch(feed.url, {
      headers: { accept: "application/zip", "user-agent": "TrainTrackerGTFSCompiler/1.0" },
      signal: AbortSignal.timeout(30_000),
    });
    if (!response.ok) throw new Error(`${feed.id} GTFS returned ${response.status}`);
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.byteLength < 1_024 || bytes.byteLength > 40 * 1_024 * 1_024) {
      throw new Error(`Unexpected ${feed.id} GTFS archive size: ${bytes.byteLength}`);
    }
    const versionFallback = response.headers.get("last-modified")?.trim() ?? "unknown";
    return {
      id: feed.id,
      url: feed.url,
      operator: feed.operator,
      source: feed.source,
      distributionApprovalReference: feed.distributionApprovalReference,
      archiveBytes: bytes.byteLength,
      sha256: createHash("sha256").update(bytes).digest("hex"),
      data: compileNorthAmericanIntercityGTFSArchive(bytes, { ...feed, feedVersionFallback: versionFallback }),
    };
  }));
  const data = mergeNorthAmericanIntercityGTFSData(sources);
  const metadata: GTFSFeedMetadata[] = sources.map((source) => ({
    id: source.id,
    url: source.url,
    operator: source.operator,
    version: source.data.feedVersion,
    sha256: source.sha256,
    source: source.source,
    distributionApprovalReference: source.distributionApprovalReference,
  }));
  const approvalRequested = process.argv.includes("--approved-output");
  let output: URL;
  let outputData = data;
  if (approvalRequested) {
    const approvedSources = sources.filter(
      (source): source is typeof source & { distributionApprovalReference: string } => (
        source.distributionApprovalReference !== null
      ),
    );
    const approvedData = mergeNorthAmericanIntercityGTFSData(approvedSources);
    outputData = approvedData;
    const approvedMetadata = metadata.filter((feed) => feed.distributionApprovalReference !== null);
    const approvalReferences = Object.fromEntries(approvedSources.map(
      (source) => [source.operator, source.distributionApprovalReference],
    ));
    output = new URL("../src/providers/north-american-intercity-gtfs-shapes.approved.ts", import.meta.url);
    await writeFile(
      output,
      renderNorthAmericanIntercityGTFSModule(approvedData, approvedMetadata, approvalReferences),
      "utf8",
    );
  } else {
    const generatedDirectory = new URL("../.generated/", import.meta.url);
    await mkdir(generatedDirectory, { recursive: true });
    output = new URL("north-american-intercity-gtfs-catalog.json", generatedDirectory);
    const artifact: GeneratedNorthAmericanIntercityGTFSArtifact = { ...data, feedMetadata: metadata };
    await writeFile(output, `${JSON.stringify(artifact)}\n`, "utf8");
  }
  console.info(JSON.stringify({
    output: output.pathname,
    approvalRequested,
    feedVersion: outputData.feedVersion,
    matches: Object.keys(outputData.matches).length,
    partialMatches: Object.keys(outputData.partialMatches).length,
    shapes: Object.keys(outputData.shapes).length,
    archiveBytes: Object.fromEntries(sources.map((source) => [source.id, source.archiveBytes])),
  }));
}

const entry = process.argv[1] === undefined ? null : pathToFileURL(resolve(process.argv[1])).href;
if (entry === import.meta.url) await generate();
