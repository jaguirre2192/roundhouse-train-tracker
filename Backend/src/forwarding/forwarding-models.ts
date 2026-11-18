export interface ForwardingAliasStatus {
  active: boolean;
  /** Recomputed on every read from the stored alias nonce and the server secret; the raw token is never persisted. */
  address: string | null;
  createdAt: string | null;
  rotatedAt: string | null;
}

export interface ForwardedTicketArtifact {
  filename: string;
  mimeType: string;
  data: string;
}

export interface ForwardedTicketSummary {
  id: string;
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
  hasArtifact: boolean;
}

export interface ParsedForwardedTicket extends Omit<ForwardedTicketSummary, "id" | "hasArtifact"> {
  messageKey: string;
  artifact: ForwardedTicketArtifact | null;
}
