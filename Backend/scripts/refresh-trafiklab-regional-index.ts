import { execFile } from "node:child_process";
import { mkdtemp, readFile, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { downloadRegionalStaticZip } from "./trafiklab-regional-static-download.js";

// Offline maintenance entry point, suitable for one daily CI invocation. It is
// never imported by the Worker. Static and realtime credentials are distinct.
const output = fileURLToPath(new URL("../src/providers/trafiklab-skane-index.generated.ts", import.meta.url));
const compiler = fileURLToPath(new URL("./generate-trafiklab-regional-index.ts", import.meta.url));
const today = new Date().toISOString().slice(0, 10);
const source = await readFile(output, "utf8").catch(() => "");
if (source.includes(`\\\"feedVersion\\\":\\\"${today}\\\"`)) {
  console.log("Skåne rail index already uses today's official feed; no static request needed.");
} else {
  const key = process.env.TRAFIKLAB_GTFS_REGIONAL_STATIC_API_KEY?.trim();
  if (!key) throw new Error("Set TRAFIKLAB_GTFS_REGIONAL_STATIC_API_KEY for the offline refresh");
  const folder = await mkdtemp(join(tmpdir(), "traintracker-skane-"));
  const staged = `${output}.pending.ts`;
  try {
    const bytes = await downloadRegionalStaticZip(key);
    const zip = join(folder, "skane.zip");
    await writeFile(zip, bytes);
    const { stdout } = await promisify(execFile)(process.execPath, ["--import", "tsx", compiler, zip, staged], { cwd: fileURLToPath(new URL("../", import.meta.url)), timeout: 180_000, maxBuffer: 1_024 * 1_024 });
    const receipt = JSON.parse(stdout.trim()) as { expiresAt: string; feedVersion: string };
    if (receipt.feedVersion !== today || Date.parse(receipt.expiresAt) <= Date.now()) throw new Error("Static source is not today's official feed; previous index preserved");
    await rename(staged, output);
    console.log(stdout.trim());
  } catch (error) {
    // Fetch exceptions may contain credential-bearing URLs in nested causes.
    throw new Error(error instanceof Error && error.message.startsWith("Regional static") ? error.message : "Skåne static refresh failed; previous index preserved");
  } finally { await Promise.all([rm(folder, { recursive: true, force: true }), rm(staged, { force: true })]); }
}
