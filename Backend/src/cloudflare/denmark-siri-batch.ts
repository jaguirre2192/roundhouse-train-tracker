import { denmarkSiriMaximumBodyBytes } from "../providers/denmark-siri-models.js";

export const denmarkSiriBatchContentType = "application/vnd.roundhouse.denmark-siri-batch+json";
export const denmarkSiriBatchLimits = {
  deliveries: 14,
  xmlBytes: denmarkSiriMaximumBodyBytes,
  // Valid XML may contain JSON-escaped quotes, slashes and whitespace. The envelope is bounded too.
  bodyBytes: 2 * denmarkSiriMaximumBodyBytes + 512,
} as const;

/** A batch never increases the aggregate XML/parse budget beyond one existing delivery. */
export function validDenmarkSiriBatch(value: unknown): value is string[] {
  if (!Array.isArray(value) || value.length < 1 || value.length > denmarkSiriBatchLimits.deliveries) return false;
  let size = 0;
  for (const xml of value) {
    if (typeof xml !== "string" || xml.length === 0 || xml.length > denmarkSiriBatchLimits.xmlBytes) return false;
    size += new TextEncoder().encode(xml).byteLength;
    if (size > denmarkSiriBatchLimits.xmlBytes) return false;
  }
  return true;
}
