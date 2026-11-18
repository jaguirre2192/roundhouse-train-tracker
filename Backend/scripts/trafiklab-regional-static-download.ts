/** Offline only: one bounded request, no retry and no credential-bearing errors. */
export async function downloadRegionalStaticZip(apiKey: string, fetcher: typeof fetch = fetch): Promise<Uint8Array> {
  try {
    const url = new URL("https://opendata.samtrafiken.se/gtfs/skane/skane.zip");
    url.searchParams.set("key", apiKey);
    const response = await fetcher(url, { signal: AbortSignal.timeout(90_000) });
    if (!response.ok) { await response.body?.cancel(); throw new Error("Static download unavailable"); }
    const reader = response.body?.getReader();
    if (!reader) throw new Error("Missing static data");
    const maximum = 64 * 1_024 * 1_024;
    if (Number(response.headers.get("content-length")) > maximum) { await reader.cancel(); throw new Error("Static archive too large"); }
    const chunks: Uint8Array[] = []; let size = 0;
    for (;;) {
      const { value, done } = await reader.read(); if (done) break;
      size += value.byteLength;
      if (size > maximum) { await reader.cancel(); throw new Error("Static archive too large"); }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    return bytes;
  } catch { throw new Error("Trafiklab static download failed; no retry was attempted"); }
}
