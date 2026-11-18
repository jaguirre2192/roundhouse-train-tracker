export interface GmailConnectionSummary {
  id: string;
  emailAddress: string;
  connectedAt: string;
  lastScanAt: string | null;
  lastError: string | null;
}

export interface GmailTicketArtifact {
  partId: string;
  attachmentId: string | null;
  filename: string;
  mimeType: string;
}

export interface GmailTicketSummary {
  id: string;
  emailAddress: string;
  subject: string;
  sender: string;
  receivedAt: string;
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
  artifact: GmailTicketArtifact | null;
}

export interface ParsedGmailTicket extends Omit<GmailTicketSummary, "id" | "emailAddress"> {
  messageId: string;
}

export interface GmailAccountSecret {
  id: string;
  userId: string;
  emailAddress: string;
  encryptedRefreshToken: string;
  historyId: string | null;
  lastScanAt: number | null;
  watchExpiresAt: number | null;
}

export interface GmailOAuthState {
  verifier: string;
  linkUserId: string;
  transactionId: string;
  appChallenge: string;
}

export type GmailConnectResult =
  | { status: "connected"; userId: string }
  | { status: "owner_conflict" }
  | { status: "account_limit" };

export type GmailManualScanResult =
  | { status: "completed"; imported: number }
  | { status: "cooldown"; retryAfter: number };

export interface GmailMessagePart {
  partId?: string;
  mimeType?: string;
  filename?: string;
  headers?: Array<{ name?: string; value?: string }>;
  body?: { attachmentId?: string; data?: string; size?: number };
  parts?: GmailMessagePart[];
}

export interface GmailMessage {
  id: string;
  internalDate?: string;
  snippet?: string;
  payload?: GmailMessagePart;
}
