const railwayEvidence = /\b(rail(?:way)?|station|platform|coach|carriage|eurostar|amtrak|intercity|shinkansen|tgv|thalys|trenitalia|renfe|sncf|deutsche\s*bahn|via\s*rail|trainline|train\s+(?:ticket|booking|reservation|confirmation|service|number|no\.?|#|\d)|tren\s+(?:con|n[uú]mero|\d))\b/iu;
const ticketIntentEvidence = /\b(ticket|e-?ticket|booking|reservation|travel\s+documents?|passenger|seat|coach|carriage|pnr|billete|reserva|pasajero|coche|asiento|accede\s+al\s+tren|c[oó]digo\s+qr)\b/iu;
const highConfidenceSubjectEvidence = /\b(?:your\s+)?(?:train|rail)\s+(?:ticket|booking|reservation|confirmation)\b|\b(?:booking|reservation)\s+confirmation\b|\be-?ticket\b|\btravel\s+documents?\b|\baccede\s+al\s+tren\s+con\s+el\s+qr\b/iu;
const nonTicketSubjectEvidence = /(?:\bmembership\s+(?:has\s+been\s+)?renewed\b|\bterms\s*(?:&|and)\s*conditions\b|\baccount\s+(?:confirmation|verification)\b|\bconfirm\s+your\s+email\b|^\s*(?:your\s+)?(?:verification|security|confirmation)\s+code\b|\bit['’]?s\s+almost\s+time\s+for\s+your\s+trip\b|^\s*[uú]ltima\s+hora\s+sobre\s+tu\s+viaje\s*$|\bget\s+ready\s+for\b)/iu;
const proseRouteEvidence = /\b(?:your|you|our|we|please|confirm|account|membership|benefits?|conditions?|terms|remind|enjoy|mailing|address|privacy|unsubscribe|click|website|actively|booking|data|travell?er|fixture)\b/iu;

const operatorDomains: Array<[RegExp, string]> = [
  [/@(?:e-?mail\.)?amtrak\.com\b/iu, "Amtrak"],
  [/@(?:mail\.)?trainline\.com\b|@thetrainline\.com\b/iu, "Trainline"],
  [/@sncf-connect\.com\b|@sncf\.fr\b/iu, "SNCF"],
  [/@bahn\.de\b|@deutschebahn\.com\b/iu, "Deutsche Bahn"],
  [/@trenitalia\.com\b/iu, "Trenitalia"],
  [/@italotreno\.com\b/iu, "Italo"],
  [/@(?:[\w-]+\.)*renfe\.es\b/iu, "Renfe"],
  [/@(?:[\w-]+\.)*eurostar\.com\b/iu, "Eurostar"],
  [/@(?:[\w-]+\.)*omio\.com\b/iu, "Omio"],
  [/@cp\.pt\b/iu, "Comboios de Portugal"],
  [/@viarail\.ca\b/iu, "VIA Rail"],
  [/@jr-central\.co\.jp\b/iu, "JR Central"],
  [/@westjr\.co\.jp\b/iu, "JR West"],
];

interface ParsedRoute {
  origin: string;
  destination: string;
}

function capture(value: string, pattern: RegExp): string | null {
  return value.match(pattern)?.[1]?.trim().replace(/[.,;]+$/u, "") ?? null;
}

function operator(sender: string, body: string): string | null {
  const domainMatch = operatorDomains.find(([pattern]) => pattern.test(sender));
  if (domainMatch !== undefined) return domainMatch[1];
  return capture(body, /(?:^|\n)\s*(?:operated by|operator)\s*:\s*([^\n]{2,48})/iu);
}

function cleanRouteEndpoint(value: string): string {
  return value
    .replace(/^\s*(?:from|origin|origen|destination|destino)\s*:\s*/iu, "")
    .split(/(?:[.!?](?:\s|$)|\s+\b(?:Train|Service|Booking|Reservation|Passenger|Travell?er|Coach|Carriage|Seat|Date|Fecha|Ready\s+for|View\s+your)\b)/iu, 1)[0]
    ?.replace(/\s+\d{1,2}:\d{2}\s*h?\s*$/iu, "")
    .trim()
    .replace(/^[,:;\s]+|[,:;\s]+$/gu, "") ?? "";
}

function isStationLike(value: string): boolean {
  const words = value.split(/\s+/u);
  return value.length >= 3
    && value.length <= 80
    && words.length <= 12
    && /[\p{L}]/u.test(value)
    && /[\p{Lu}]/u.test(value)
    && !proseRouteEvidence.test(value)
    && !/https?:|www\.|@/iu.test(value);
}

function extractRoute(body: string): ParsedRoute | null {
  const labeledOrigin = capture(body, /(?:^|\n)\s*(?:origin|from|origen)\s*:\s*([^\n]{2,120})/iu);
  const labeledDestination = capture(body, /(?:^|\n)\s*(?:destination|to|destino)\s*:\s*([^\n]{2,120})/iu);
  if (labeledOrigin !== null && labeledDestination !== null) {
    const origin = cleanRouteEndpoint(labeledOrigin);
    const destination = cleanRouteEndpoint(labeledDestination);
    if (isStationLike(origin) && isStationLike(destination)) return { origin, destination };
  }

  for (const line of body.split("\n")) {
    for (const segment of line.split(/[.!?]\s+/u)) {
      const match = segment.match(/^\s*(?:from\s+)?(.{2,90}?)\s+(?:to|→|–|—)\s+(.{2,140})\s*$/iu);
      if (match === null) continue;
      let origin = cleanRouteEndpoint(match[1] ?? "");
      // "Your journey is from Brussels Midi to Amsterdam Centraal": the station
      // starts after the last "from" in the sentence.
      if (!isStationLike(origin)) origin = cleanRouteEndpoint(origin.split(/\bfrom\s+/iu).pop() ?? "");
      const destination = cleanRouteEndpoint(match[2] ?? "");
      if (isStationLike(origin) && isStationLike(destination)) return { origin, destination };
    }
  }
  return null;
}

function extractPassenger(body: string): string | null {
  const value = capture(body, /\b(?:passenger|travell?er|pasajero)\s*:\s*([^\n]{2,80})/iu);
  if (value === null) return null;
  const cleaned = value.split(/\s+\b(?:Coach|Carriage|Seat|Booking|Reservation)\b/iu, 1)[0]?.trim() ?? "";
  return /^[\p{L}][\p{L} .'’-]{1,60}$/u.test(cleaned) ? cleaned : null;
}

function extractDate(body: string): string | null {
  const numeric = body.match(/\b(?:Fecha|Date)\s*:\s*(\d{1,2})[\/.](\d{1,2})[\/.](\d{4})\b/iu);
  if (numeric !== null) {
    const [, day = "", month = "", year = ""] = numeric;
    return `${year}-${month.padStart(2, "0")}-${day.padStart(2, "0")}`;
  }

  const english = body.match(/\b(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*,?\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+(\d{1,2}),\s+(\d{4})\b/iu);
  if (english === null) return null;
  const months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
  const month = months.indexOf((english[1] ?? "").slice(0, 3).toLowerCase()) + 1;
  if (month === 0) return null;
  return `${english[3]}-${String(month).padStart(2, "0")}-${(english[2] ?? "").padStart(2, "0")}`;
}

function madridOffset(date: string): string {
  try {
    const offsetName = new Intl.DateTimeFormat("en", {
      timeZone: "Europe/Madrid",
      timeZoneName: "longOffset",
    }).formatToParts(new Date(`${date}T12:00:00Z`))
      .find((part) => part.type === "timeZoneName")?.value;
    return offsetName?.replace("GMT", "") || "+01:00";
  } catch {
    return "+01:00";
  }
}

function extractDepartureTime(body: string, operatorName: string | null): string | null {
  const date = extractDate(body);
  if (date === null) return null;
  const time = body.match(/(?:^|\n)\s*(?:Origin|From|Origen|Departure|Salida)\s*:[^\n]*?\b(\d{1,2}):(\d{2})\s*h?\b/iu);
  if (time === null) return date;
  // A local departure time without a known station/operator timezone is more
  // misleading than a date-only value. The app can ask the rider to confirm
  // the time instead of silently treating an unknown local time as UTC.
  if (operatorName !== "Renfe") return date;
  const hour = (time[1] ?? "").padStart(2, "0");
  const minute = time[2] ?? "00";
  const offset = madridOffset(date);
  return `${date}T${hour}:${minute}:00${offset}`;
}

export interface TicketEvidenceInput {
  subject: string;
  sender: string;
  bodyText: string;
  extraContext?: string;
  hasAttachment: boolean;
}

export interface TicketFields {
  operatorName: string | null;
  trainNumber: string | null;
  originName: string | null;
  destinationName: string | null;
  departureTime: string | null;
  arrivalTime: string | null;
  bookingReference: string | null;
  passengerName: string | null;
  coach: string | null;
  seat: string | null;
}

// Rail emails routinely attach logos and banners as images, so an image only
// counts as a ticket when its filename says so. A PDF attachment always counts.
const ticketFilenameEvidence = /(?:^|[^\p{L}])(?:e[-_ ]?tickets?|tickets?|booking|reservation|boarding|pass|itinerary|voucher|qr|barcode|billet|fahrkarte|biglietto|billete|bilhete)(?:[^\p{L}]|$)/iu;

export function isTicketEvidenceAttachment(mimeType: string, filename: string | null | undefined): boolean {
  if (/^application\/pdf$/iu.test(mimeType)) return true;
  return /^image\//iu.test(mimeType) && ticketFilenameEvidence.test(filename?.trim() ?? "");
}

/** Lower is better: a PDF, then a ticket-named image, then any other image. */
export function ticketAttachmentRank(mimeType: string, filename: string | null | undefined): number {
  if (/^application\/pdf$/iu.test(mimeType)) return 0;
  return isTicketEvidenceAttachment(mimeType, filename) ? 1 : 2;
}

export function isRejectedTicketSubject(subject: string): boolean {
  return nonTicketSubjectEvidence.test(subject);
}

export function extractTicketFields(input: TicketEvidenceInput): TicketFields | null {
  const { subject, sender, bodyText: body, extraContext = "", hasAttachment } = input;
  const context = `${subject}\n${sender}\n${extraContext}\n${body}`;
  const operatorName = operator(sender, body);
  const route = extractRoute(body);
  const trainNumber = capture(body, /\b(?:train|service|tren)\s*(?:number|n[uú]mero|no\.?|#)?\s*[:#]?\s*([A-Z]{0,4}\s?\d{1,6})\b/iu);
  const bookingReference = capture(body, /\b(?:booking|reservation|reserva)\s*(?:number|reference|referencia|ref|code|c[oó]digo|no\.?)\s*[:#]?\s*([A-Z0-9][A-Z0-9-]{4,19})\b/iu);
  const coach = capture(body, /\b(?:coach|carriage|coche)\s*(?:number|n[uú]mero|no\.?)?\s*[:#]?\s*([A-Z0-9-]{1,8})\b/iu);
  const seat = capture(body, /\b(?:seat|asiento|plaza)\s*(?:number|n[uú]mero|no\.?)?\s*[:#]?\s*([A-Z0-9-]{1,8})\b/iu);
  const passengerName = extractPassenger(body);
  const departureTime = extractDepartureTime(body, operatorName);

  const hasRailContext = operatorName !== null || railwayEvidence.test(context);
  const hasTicketIntent = ticketIntentEvidence.test(context);
  const hasOwnershipEvidence = passengerName !== null || coach !== null || seat !== null;
  // A public service identifier is common in advisories, delay notices,
  // cancellation alerts, and marketing. It only becomes ticket evidence when
  // the message also contains rider-specific details. Likewise, an ordinary
  // route and date are a timetable until ownership evidence ties them to the
  // recipient.
  const hasOwnedTrainDetails = trainNumber !== null && hasOwnershipEvidence;
  const hasOwnedDatedRoute = route !== null && departureTime !== null && hasOwnershipEvidence;
  const hasStrongTicketEvidence = bookingReference !== null
    || hasOwnedTrainDetails
    || hasOwnedDatedRoute
    || (hasAttachment && hasTicketIntent)
    || (route !== null && highConfidenceSubjectEvidence.test(subject));
  if (!hasRailContext || !hasStrongTicketEvidence) return null;

  return {
    operatorName,
    trainNumber,
    originName: route?.origin ?? null,
    destinationName: route?.destination ?? null,
    departureTime,
    arrivalTime: null,
    bookingReference,
    passengerName,
    coach,
    seat,
  };
}
