import { normalizeEmailText } from "../ticket-import/email-text.js";
import {
  extractTicketFields,
  isRejectedTicketSubject,
  isTicketEvidenceAttachment,
  ticketAttachmentRank,
} from "../ticket-import/ticket-evidence.js";
import type {
  GmailMessage,
  GmailMessagePart,
  GmailTicketArtifact,
  ParsedGmailTicket,
} from "./gmail-models.js";

function decodeBase64URL(value: string): string {
  const normalized = value.replace(/-/gu, "+").replace(/_/gu, "/");
  const bytes = Uint8Array.from(atob(normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=")), (character) => (
    character.charCodeAt(0)
  ));
  return new TextDecoder().decode(bytes);
}

function header(part: GmailMessagePart | undefined, name: string): string {
  return part?.headers?.find((candidate) => candidate.name?.toLowerCase() === name)?.value ?? "";
}

function flattenParts(part: GmailMessagePart | undefined): GmailMessagePart[] {
  if (part === undefined) return [];
  return [part, ...(part.parts ?? []).flatMap(flattenParts)];
}

function readableBody(parts: GmailMessagePart[]): string {
  const text = parts
    .filter((part) => part.body?.data !== undefined && (
      part.mimeType === "text/plain" || part.mimeType === "text/html"
    ))
    .map((part) => decodeBase64URL(part.body?.data ?? ""))
    .join("\n");
  return normalizeEmailText(text);
}

// Same rule as forwarded tickets: prefer a PDF, then a ticket-named image.
function artifact(parts: GmailMessagePart[]): GmailTicketArtifact | null {
  const candidate = parts
    .map((part, index) => ({ part, index }))
    .filter(({ part }) => {
      const type = part.mimeType ?? "";
      return part.body?.attachmentId !== undefined && (
        type === "application/pdf" || type.startsWith("image/")
      );
    })
    .sort((a, b) =>
      ticketAttachmentRank(a.part.mimeType ?? "", a.part.filename) - ticketAttachmentRank(b.part.mimeType ?? "", b.part.filename)
      || a.index - b.index
    )[0]?.part;
  if (candidate?.body?.attachmentId === undefined) return null;
  return {
    partId: candidate.partId ?? "",
    attachmentId: candidate.body.attachmentId,
    filename: candidate.filename?.trim() || "Train ticket",
    mimeType: candidate.mimeType ?? "application/octet-stream",
  };
}

export function isRejectedGmailSubject(subject: string): boolean {
  return isRejectedTicketSubject(subject);
}

export function parseGmailTicket(message: GmailMessage): ParsedGmailTicket | null {
  const parts = flattenParts(message.payload);
  const subject = header(message.payload, "subject") || "Train ticket";
  const sender = header(message.payload, "from");
  const body = readableBody(parts);
  const ticketArtifact = artifact(parts);

  if (isRejectedGmailSubject(subject)) return null;

  const fields = extractTicketFields({
    subject,
    sender,
    bodyText: body,
    extraContext: message.snippet ?? "",
    hasAttachment: ticketArtifact !== null
      && isTicketEvidenceAttachment(ticketArtifact.mimeType, parts.find((part) =>
        part.body?.attachmentId === ticketArtifact.attachmentId)?.filename),
  });
  if (fields === null) return null;

  const received = Number(message.internalDate ?? Date.now());
  return {
    messageId: message.id,
    subject: subject.slice(0, 300),
    sender: sender.slice(0, 300),
    receivedAt: new Date(Number.isFinite(received) ? received : Date.now()).toISOString(),
    ...fields,
    artifact: ticketArtifact,
  };
}
