import { denmarkSiriMaximumBodyBytes } from "./denmark-siri-models.js";
import { parseDenmarkSiriDelivery } from "./denmark-siri-parser.js";

const maximumInputBytes = 20 * 1_024 * 1_024;
const maximumOutputBytes = 24 * 1_024 * 1_024;
const maximumJourneys = 2_000;
const maximumNodes = 500_000;
const siri = "http://www.siri.org.uk/siri";
const path = ["Siri", "ServiceDelivery", "EstimatedTimetableDelivery", "EstimatedJourneyVersionFrame", "EstimatedVehicleJourney"];
interface Frame { qualified: string; local: string; namespace: string; namespaces: Map<string, string>; start: number }
interface Range { start: number; end: number }

export class DenmarkSiriFragmentError extends Error {
  constructor(readonly code: "invalid-xml" | "body-limit" | "journey-limit") {
    super(`Denmark SIRI fragmentation: ${code}`); this.name = "DenmarkSiriFragmentError";
  }
}

/** Eagerly validates the complete publication before any caller can publish.
 * Large envelopes split only at whole, namespace-qualified vehicle journeys.
 * All surrounding XML, original clocks, namespaces and sequence flags survive. */
export function fragmentDenmarkSiriDelivery(bytes: Uint8Array, receivedAt: string): Uint8Array[] {
  if (bytes.byteLength === 0 || bytes.byteLength > maximumInputBytes) throw new DenmarkSiriFragmentError("body-limit");
  let xml: string;
  try { xml = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes); }
  catch { throw new DenmarkSiriFragmentError("invalid-xml"); }
  if (bytes.byteLength <= denmarkSiriMaximumBodyBytes && parseDenmarkSiriDelivery(xml, receivedAt) !== null) return [bytes];
  const ranges = journeyRanges(xml);
  if (ranges.length === 0) throw new DenmarkSiriFragmentError("invalid-xml");
  const pieces: string[] = [];
  let cursor = 0;
  for (const range of ranges) { pieces.push(xml.slice(cursor, range.start)); cursor = range.end; }
  pieces.push(xml.slice(cursor));
  const encoder = new TextEncoder();
  const envelopeBytes = encoder.encode(pieces.join("")).byteLength;
  if (envelopeBytes >= denmarkSiriMaximumBodyBytes) throw new DenmarkSiriFragmentError("body-limit");
  const journeyBytes = ranges.map(range => encoder.encode(xml.slice(range.start, range.end)).byteLength);
  if (envelopeBytes * ranges.length + journeyBytes.reduce((sum, size) => sum + size, 0) > maximumOutputBytes) {
    throw new DenmarkSiriFragmentError("body-limit");
  }
  // Each fragment retains every envelope/frame and its metadata; only the other
  // whole journey elements are absent. No call-list or completeness rewriting.
  return ranges.map((range, selected) => {
    const journey = xml.slice(range.start, range.end);
    if (envelopeBytes + journeyBytes[selected]! > denmarkSiriMaximumBodyBytes) {
      throw new DenmarkSiriFragmentError("body-limit");
    }
    const fragment = pieces.map((piece, index) => piece + (index === selected ? journey : "")).join("");
    if (parseDenmarkSiriDelivery(fragment, receivedAt) === null) throw new DenmarkSiriFragmentError("invalid-xml");
    return encoder.encode(fragment);
  });
}

/** Structural scan stores only bounded ancestry and byte-preserving ranges.
 * Existing source parser then validates every resulting complete envelope. */
function journeyRanges(xml: string): Range[] {
  if (/<!DOCTYPE|<!ENTITY/iu.test(xml)) throw new DenmarkSiriFragmentError("invalid-xml");
  const stack: Frame[] = [], ranges: Range[] = [];
  const tokens = /<\?[\s\S]*?\?>|<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\/?[A-Za-z_][\w:.-]*(?:\s+(?:[^<>"']|"[^"]*"|'[^']*')*)?\s*\/?>|[^<]+/gu;
  let cursor = 0, nodes = 0, roots = 0;
  const relevant = () => stack.length === path.length && stack.every((frame, i) => frame.local === path[i] && frame.namespace === siri);
  for (const token of xml.matchAll(tokens)) {
    if (token.index !== cursor) throw new DenmarkSiriFragmentError("invalid-xml");
    const text = token[0], start = cursor; cursor += text.length;
    if (text.startsWith("<?") || text.startsWith("<!--")) continue;
    if (text.startsWith("<![CDATA[")) {
      if (stack.length === 0) throw new DenmarkSiriFragmentError("invalid-xml");
      continue;
    }
    if (text.startsWith("<![CDATA[")) { if (stack.length === 0) throw new DenmarkSiriFragmentError("invalid-xml"); continue; }
    if (text.startsWith("</")) {
      const isJourney = relevant(), frame = stack.pop();
      if (frame?.qualified !== text.slice(2, -1).trim()) throw new DenmarkSiriFragmentError("invalid-xml");
      if (isJourney) ranges.push({ start: frame.start, end: cursor });
    } else if (text.startsWith("<")) {
      if (++nodes > maximumNodes || stack.length > 32) throw new DenmarkSiriFragmentError("body-limit");
      const qualified = /^<([\w:.-]+)/u.exec(text)?.[1];
      if (qualified === undefined) throw new DenmarkSiriFragmentError("invalid-xml");
      const namespaces = new Map(stack.at(-1)?.namespaces);
      for (const attribute of text.matchAll(/\bxmlns(?::([\w.-]+))?\s*=\s*(["'])(.*?)\2/gu)) namespaces.set(attribute[1] ?? "", attribute[3]!);
      const parts = qualified.split(":");
      const namespace = namespaces.get(parts.length === 2 ? parts[0]! : "") ?? "";
      if (parts.length > 2 || parts.length === 2 && namespace.length === 0) throw new DenmarkSiriFragmentError("invalid-xml");
      if (stack.length === 0 && ++roots > 1) throw new DenmarkSiriFragmentError("invalid-xml");
      stack.push({ qualified, local: parts.at(-1)!, namespace, namespaces, start });
      if (text.endsWith("/>")) { if (relevant()) ranges.push({ start, end: cursor }); stack.pop(); }
    } else if (stack.length === 0 && text.trim().length > 0) throw new DenmarkSiriFragmentError("invalid-xml");
    if (ranges.length > maximumJourneys) throw new DenmarkSiriFragmentError("journey-limit");
  }
  if (cursor !== xml.length || stack.length !== 0 || roots !== 1) throw new DenmarkSiriFragmentError("invalid-xml");
  return ranges;
}
