import PostalMime from "postal-mime";
import { normalizeEmailText } from "../ticket-import/email-text.js";
import {
  extractTicketFields,
  isRejectedTicketSubject,
  isTicketEvidenceAttachment,
  ticketAttachmentRank,
} from "../ticket-import/ticket-evidence.js";
import type { ForwardedTicketArtifact, ParsedForwardedTicket } from "./forwarding-models.js";

// Keeps a stored artifact comfortably under Durable Object SQLite's per-row
// size ceiling once base64-encoded (roughly 4/3 of the raw byte count).
const maxArtifactBytes = 1_500_000;
const artifactMimePattern = /^application\/pdf$|^image\/(?:png|jpe?g|heic|webp)$/iu;
const maxMimeNestingDepth = 10;

interface ParsedAttachment {
  filename: string | null;
  mimeType: string;
  content: ArrayBuffer | Uint8Array | string;
}

interface ParsedEmail {
  subject?: string;
  from?: { address?: string };
  date?: string;
  text?: string;
  html?: string;
  attachments: ParsedAttachment[];
}

function base64ByteLength(base64: string): number {
  const padding = base64.endsWith("==") ? 2 : base64.endsWith("=") ? 1 : 0;
  return Math.floor((base64.length * 3) / 4) - padding;
}

interface SelectedArtifact {
  artifact: ForwardedTicketArtifact;
  isTicketEvidence: boolean;
}

// Prefers a PDF, then a ticket-named image, so a leading logo never stands in
// for the ticket. Any other image is still kept (a forwarded screenshot of a
// QR code is often named IMG_1234.jpg) but does not count as ticket evidence.
function selectArtifact(attachments: ParsedAttachment[]): SelectedArtifact | null {
  const candidates = attachments.filter((attachment): attachment is ParsedAttachment & { content: string } =>
    typeof attachment.content === "string"
    && artifactMimePattern.test(attachment.mimeType)
    && base64ByteLength(attachment.content) <= maxArtifactBytes
  );
  const best = candidates
    .map((attachment, index) => ({ attachment, index, rank: ticketAttachmentRank(attachment.mimeType, attachment.filename) }))
    .sort((a, b) => a.rank - b.rank || a.index - b.index)[0]?.attachment;
  if (best === undefined) return null;
  return {
    artifact: {
      filename: (best.filename ?? "Train ticket").trim().slice(0, 200) || "Train ticket",
      mimeType: best.mimeType,
      data: best.content,
    },
    isTicketEvidence: isTicketEvidenceAttachment(best.mimeType, best.filename),
  };
}

function bodyText(email: ParsedEmail): string {
  if (email.text !== undefined && email.text.trim().length > 0) return normalizeEmailText(email.text);
  if (email.html !== undefined) return normalizeEmailText(email.html);
  return "";
}

// postal-mime only rewrites a header it can parse into ISO-8601; anything
// else is left as the raw, possibly malformed header value, so a definite
// re-parse (rather than trusting the field's mere presence) decides whether
// to trust it over the Worker's own receipt time.
function receivedAt(email: ParsedEmail): string {
  if (email.date !== undefined) {
    const parsed = new Date(email.date);
    if (!Number.isNaN(parsed.getTime())) return parsed.toISOString();
  }
  return new Date().toISOString();
}

/**
 * Parses a raw forwarded RFC 822 message into a rail ticket, reusing the same
 * evidence heuristics as Gmail import. Returns null for anything that is not
 * a high-confidence rail ticket (including messages postal-mime cannot
 * usefully decode) rather than throwing, so the email handler can silently
 * drop low-confidence forwards instead of bouncing them.
 */
export async function parseForwardedTicket(
  raw: ArrayBuffer,
  messageKey: string,
): Promise<ParsedForwardedTicket | null> {
  const email = await PostalMime.parse(raw, {
    attachmentEncoding: "base64",
    maxNestingDepth: maxMimeNestingDepth,
  }) as ParsedEmail;

  const subject = (email.subject ?? "").trim().slice(0, 300) || "Train ticket";
  const sender = (email.from?.address ?? "").trim().slice(0, 300) || "unknown";
  if (isRejectedTicketSubject(subject)) return null;

  const selected = selectArtifact(email.attachments);
  const fields = extractTicketFields({
    subject,
    sender,
    bodyText: bodyText(email),
    hasAttachment: selected?.isTicketEvidence ?? false,
  });
  if (fields === null) return null;

  return {
    messageKey,
    subject,
    sender,
    receivedAt: receivedAt(email),
    ...fields,
    artifact: selected?.artifact ?? null,
  };
}
