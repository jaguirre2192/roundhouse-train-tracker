import { denmarkSiriMaximumBodyBytes, isDenmarkSiriOperatorRef, type DenmarkSiriCall, type DenmarkSiriJourney } from "./denmark-siri-models.js";

interface Node { name: string; namespace: string; text: string; children: Node[] }
interface Frame { qualified: string; node: Node; namespaces: Map<string, string> }
const siriNamespace = "http://www.siri.org.uk/siri";

function decoded(value: string): string {
  return value.replace(/&(?:amp|lt|gt|quot|apos|#\d+|#x[\da-f]+);/giu, (entity) => {
    const known: Record<string, string> = { "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": '"', "&apos;": "'" };
    if (known[entity] !== undefined) return known[entity]!;
    const number = entity.startsWith("&#x") ? parseInt(entity.slice(3, -1), 16) : Number(entity.slice(2, -1));
    return number > 0 && number <= 0x10ffff && !(number >= 0xd800 && number <= 0xdfff)
      ? String.fromCodePoint(number) : "";
  });
}

/** A bounded XML tree reader for this source, with no DTD/entity expansion. */
function tree(xml: string): Node | null {
  if (new TextEncoder().encode(xml).byteLength > denmarkSiriMaximumBodyBytes || /<!DOCTYPE|<!ENTITY/iu.test(xml)) return null;
  const stack: Frame[] = [];
  let root: Node | null = null;
  let cursor = 0;
  let nodes = 0;
  const tokens = /<\?[\s\S]*?\?>|<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\/?[A-Za-z_][\w:.-]*(?:\s+(?:[^<>"']|"[^"]*"|'[^']*')*)?\s*\/?>|[^<]+/gu;
  for (const token of xml.matchAll(tokens)) {
    if (token.index !== cursor) return null;
    const text = token[0];
    cursor += text.length;
    if (text.startsWith("<?") || text.startsWith("<!--")) continue;
    if (text.startsWith("<![CDATA[")) {
      if (stack.length === 0) return null;
      stack.at(-1)!.node.text += text.slice(9, -3);
    } else if (text.startsWith("</")) {
      const qualified = text.slice(2, -1).trim();
      if (stack.pop()?.qualified !== qualified) return null;
    } else if (text.startsWith("<")) {
      if (++nodes > 10_000 || stack.length > 32) return null;
      const qualified = /^<([\w:.-]+)/u.exec(text)?.[1];
      if (qualified === undefined) return null;
      const namespaces = new Map(stack.at(-1)?.namespaces);
      for (const attribute of text.matchAll(/\bxmlns(?::([\w.-]+))?\s*=\s*(["'])(.*?)\2/gu)) {
        namespaces.set(attribute[1] ?? "", attribute[3]!);
      }
      const parts = qualified.split(":");
      if (parts.length > 2) return null;
      const namespace = namespaces.get(parts.length === 2 ? parts[0]! : "") ?? "";
      if (parts.length === 2 && namespace.length === 0) return null;
      const node: Node = { name: parts.at(-1)!, namespace, text: "", children: [] };
      if (stack.length === 0) {
        if (root !== null) return null;
        root = node;
      } else stack.at(-1)!.node.children.push(node);
      if (!text.endsWith("/>")) stack.push({ qualified, node, namespaces });
    } else if (stack.length === 0) {
      if (text.trim().length > 0) return null;
    } else stack.at(-1)!.node.text += decoded(text);
  }
  return cursor === xml.length && stack.length === 0 && root?.namespace === siriNamespace ? root : null;
}

function children(node: Node, name: string): Node[] {
  return node.children.filter((child) => child.namespace === siriNamespace && child.name === name);
}
function child(node: Node, name: string): Node | null {
  const matches = children(node, name);
  return matches.length === 1 ? matches[0]! : null;
}
function value(node: Node, name: string): string | null {
  const item = child(node, name);
  return item !== null && item.children.length === 0 ? item.text.trim() || null : null;
}
function timestamp(value: string | null): string | null {
  if (value === null || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)$/u.test(value)) return null;
  if (!date(value.slice(0, 10)) || Number(value.slice(11, 13)) > 23
    || Number(value.slice(14, 16)) > 59 || Number(value.slice(17, 19)) > 59) return null;
  const instant = Date.parse(value);
  return Number.isFinite(instant) ? new Date(instant).toISOString() : null;
}
function date(value: string | null): value is string {
  return value !== null && /^\d{4}-\d\d-\d\d$/u.test(value)
    && Number.isFinite(Date.parse(value)) && new Date(value).toISOString().slice(0, 10) === value;
}

function calls(journey: Node, observedAt: string): DenmarkSiriCall[] {
  const nodes = ["RecordedCalls", "EstimatedCalls"].flatMap((group) => {
    const parent = child(journey, group);
    return parent === null ? [] : children(parent, group === "RecordedCalls" ? "RecordedCall" : "EstimatedCall");
  });
  return nodes.flatMap((call): DenmarkSiriCall[] => {
    const stopPointRef = value(call, "StopPointRef");
    if (stopPointRef === null || !/^86\d{5}$/u.test(stopPointRef) || value(call, "PredictionInaccurate") === "true") return [];
    const aimedArrival = timestamp(value(call, "AimedArrivalTime"));
    const aimedDeparture = timestamp(value(call, "AimedDepartureTime"));
    if (aimedArrival === null && aimedDeparture === null) return [];
    const expectedArrival = aimedArrival === null ? null : timestamp(value(call, "ExpectedArrivalTime"));
    const expectedDeparture = aimedDeparture === null ? null : timestamp(value(call, "ExpectedDepartureTime"));
    // RecordedCall alone proves no arrival/passage. Unsupported fields are withheld.
    if (expectedArrival === null && expectedDeparture === null) return [];
    return [{ stopPointRef, aimedArrival, aimedDeparture, observedAt,
      ...(expectedArrival === null ? {} : { expectedArrival }),
      ...(expectedDeparture === null ? {} : { expectedDeparture }) }];
  });
}

export function parseDenmarkSiriDelivery(xml: string, receivedAt: string): { journeys: DenmarkSiriJourney[] } | null {
  const root = tree(xml);
  const received = timestamp(receivedAt);
  if (root === null || root.name !== "Siri" || received === null) return null;
  const service = child(root, "ServiceDelivery");
  if (service === null) return null;
  const responseTimestamp = timestamp(value(service, "ResponseTimestamp"));
  const producerRef = value(service, "ProducerRef");
  if (responseTimestamp === null || producerRef !== "RKRP_RTH"
    || Date.parse(responseTimestamp) > Date.parse(received) + 120_000) return null;
  const deliveries = children(service, "EstimatedTimetableDelivery");
  if (deliveries.length === 0) return null;
  let invalidFuture = false;
  const journeys = deliveries.flatMap((delivery) =>
    children(delivery, "EstimatedJourneyVersionFrame").flatMap((frame) =>
      children(frame, "EstimatedVehicleJourney").flatMap((journey): DenmarkSiriJourney[] => {
        const reference = child(journey, "FramedVehicleJourneyRef");
        const serviceDate = reference === null ? null : value(reference, "DataFrameRef");
        const journeyRef = reference === null ? null : value(reference, "DatedVehicleJourneyRef");
        const observedAt = timestamp(value(journey, "RecordedAtTime"));
        const operatorRef = value(journey, "OperatorRef");
        if (isDenmarkSiriOperatorRef(operatorRef) && observedAt !== null
          && Date.parse(observedAt) > Date.parse(responseTimestamp) + 120_000) {
          invalidFuture = true;
          return [];
        }
        const numbers = child(journey, "TrainNumbers");
        const number = numbers === null ? null : value(numbers, "TrainNumberRef");
        if (!date(serviceDate) || journeyRef === null || journeyRef.length > 200 || observedAt === null
          || number === null || !/^\d{1,6}$/u.test(number) || !isDenmarkSiriOperatorRef(operatorRef)
          || value(journey, "Monitored") !== "true" || value(journey, "PredictionInaccurate") === "true"
          || Date.parse(observedAt) > Date.parse(responseTimestamp) + 120_000) return [];
        const parsedCalls = calls(journey, observedAt);
        if (parsedCalls.length === 0) return [];
        return [{ producerRef, responseTimestamp, receivedAt: received, operatorRef, serviceDate,
          journeyRef, trainNumber: number.replace(/^0+/u, "") || "0", observedAt,
          completeStopSequence: value(journey, "IsCompleteStopSequence") === "true", calls: parsedCalls }];
      })));
  return invalidFuture ? null : { journeys };
}

export function parseDenmarkSiriEvents(xml: string, receivedAt: string): DenmarkSiriJourney[] {
  return parseDenmarkSiriDelivery(xml, receivedAt)?.journeys ?? [];
}
