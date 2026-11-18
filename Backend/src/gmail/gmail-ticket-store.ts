import type {
  GmailAccountSecret,
  GmailTicketSummary,
  ParsedGmailTicket,
} from "./gmail-models.js";

interface TicketRow extends Record<string, SqlStorageValue> {
  id: string;
  email_address: string;
  subject: string;
  sender: string;
  received_at: number;
  operator_name: string | null;
  train_number: string | null;
  origin_name: string | null;
  destination_name: string | null;
  departure_time: string | null;
  arrival_time: string | null;
  booking_reference: string | null;
  passenger_name: string | null;
  coach: string | null;
  seat: string | null;
  artifact_json: string | null;
}

export interface GmailTicketArtifactDescriptor {
  account: GmailAccountSecret;
  messageId: string;
  artifact: NonNullable<GmailTicketSummary["artifact"]>;
}

export class GmailTicketStore {
  constructor(private readonly sql: SqlStorage) {}

  upsert(accountId: string, ticket: ParsedGmailTicket, now = Date.now()): void {
    const id = `${accountId}:${ticket.messageId}`;
    this.sql.exec(
      `INSERT INTO gmail_tickets
         (id, account_id, message_id, subject, sender, received_at, operator_name, train_number,
          origin_name, destination_name, departure_time, arrival_time, booking_reference,
          passenger_name, coach, seat, artifact_json, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (account_id, message_id) DO UPDATE SET
         subject = excluded.subject, sender = excluded.sender, received_at = excluded.received_at,
         operator_name = excluded.operator_name, train_number = excluded.train_number,
         origin_name = excluded.origin_name, destination_name = excluded.destination_name,
         departure_time = excluded.departure_time, arrival_time = excluded.arrival_time,
         booking_reference = excluded.booking_reference, passenger_name = excluded.passenger_name,
         coach = excluded.coach, seat = excluded.seat, artifact_json = excluded.artifact_json,
         updated_at = excluded.updated_at`,
      id,
      accountId,
      ticket.messageId,
      ticket.subject,
      ticket.sender,
      Date.parse(ticket.receivedAt),
      ticket.operatorName,
      ticket.trainNumber,
      ticket.originName,
      ticket.destinationName,
      ticket.departureTime,
      ticket.arrivalTime,
      ticket.bookingReference,
      ticket.passengerName,
      ticket.coach,
      ticket.seat,
      ticket.artifact === null ? null : JSON.stringify(ticket.artifact),
      now,
      now,
    );
  }

  remove(accountId: string, messageId: string): void {
    this.sql.exec(
      "DELETE FROM gmail_tickets WHERE account_id = ? AND message_id = ?",
      accountId,
      messageId,
    );
  }

  removeMatchingSubjects(accountId: string, predicate: (subject: string) => boolean): number {
    const rows = this.sql.exec<{ message_id: string; subject: string }>(
      "SELECT message_id, subject FROM gmail_tickets WHERE account_id = ?",
      accountId,
    ).toArray();
    const rejected = rows.filter((row) => predicate(row.subject));
    for (const row of rejected) this.remove(accountId, row.message_id);
    return rejected.length;
  }

  forUser(userId: string): GmailTicketSummary[] {
    return this.sql.exec<TicketRow>(
      `SELECT gmail_tickets.id, gmail_accounts.email_address, subject, sender, received_at,
              operator_name, train_number, origin_name, destination_name, departure_time,
              arrival_time, booking_reference, passenger_name, coach, seat, artifact_json
       FROM gmail_tickets JOIN gmail_accounts ON gmail_accounts.id = gmail_tickets.account_id
       WHERE gmail_accounts.user_id = ? ORDER BY received_at DESC LIMIT 200`,
      userId,
    ).toArray().map((row) => ({
      id: row.id,
      emailAddress: row.email_address,
      subject: row.subject,
      sender: row.sender,
      receivedAt: new Date(row.received_at).toISOString(),
      operatorName: row.operator_name,
      trainNumber: row.train_number,
      originName: row.origin_name,
      destinationName: row.destination_name,
      departureTime: row.departure_time,
      arrivalTime: row.arrival_time,
      bookingReference: row.booking_reference,
      passengerName: row.passenger_name,
      coach: row.coach,
      seat: row.seat,
      artifact: row.artifact_json === null ? null : JSON.parse(row.artifact_json),
    }));
  }

  artifact(userId: string, ticketId: string): GmailTicketArtifactDescriptor | null {
    const row = this.sql.exec<{
      message_id: string;
      artifact_json: string | null;
      id: string;
      user_id: string;
      email_address: string;
      encrypted_refresh_token: string;
      history_id: string | null;
      watch_expires_at: number | null;
      last_scan_at: number | null;
    }>(
      `SELECT gmail_tickets.message_id, gmail_tickets.artifact_json, gmail_accounts.id,
              gmail_accounts.user_id, gmail_accounts.email_address,
              gmail_accounts.encrypted_refresh_token, gmail_accounts.history_id,
              gmail_accounts.watch_expires_at, gmail_accounts.last_scan_at
       FROM gmail_tickets JOIN gmail_accounts ON gmail_accounts.id = gmail_tickets.account_id
       WHERE gmail_tickets.id = ? AND gmail_accounts.user_id = ?`,
      ticketId,
      userId,
    ).toArray()[0];
    if (row === undefined || row.artifact_json === null) return null;
    return {
      account: {
        id: row.id,
        userId: row.user_id,
        emailAddress: row.email_address,
        encryptedRefreshToken: row.encrypted_refresh_token,
        historyId: row.history_id,
        lastScanAt: row.last_scan_at,
        watchExpiresAt: row.watch_expires_at,
      },
      messageId: row.message_id,
      artifact: JSON.parse(row.artifact_json),
    };
  }
}
