import type { ForwardedTicketSummary, ParsedForwardedTicket } from "./forwarding-models.js";

interface AliasRow extends Record<string, SqlStorageValue> {
  alias_nonce: string;
  token_hash: string;
  created_at: number;
  rotated_at: number;
}

interface TicketRow extends Record<string, SqlStorageValue> {
  id: string;
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
  artifact_data: string | null;
}

export interface ForwardingAliasRecord {
  aliasNonce: string;
  tokenHash: string;
  createdAt: number;
  rotatedAt: number;
}

export interface ForwardedTicketArtifactDescriptor {
  filename: string;
  mimeType: string;
  data: string;
}

export class ForwardingRepository {
  private readonly sql: SqlStorage;

  constructor(private readonly storage: DurableObjectStorage) {
    this.sql = storage.sql;
  }

  aliasStatus(userId: string): ForwardingAliasRecord | null {
    const row = this.sql.exec<AliasRow>(
      "SELECT alias_nonce, token_hash, created_at, rotated_at FROM forwarding_aliases WHERE user_id = ?",
      userId,
    ).toArray()[0];
    return row === undefined
      ? null
      : { aliasNonce: row.alias_nonce, tokenHash: row.token_hash, createdAt: row.created_at, rotatedAt: row.rotated_at };
  }

  upsertAlias(userId: string, aliasNonce: string, tokenHash: string, now = Date.now()): ForwardingAliasRecord {
    return this.storage.transactionSync(() => {
      this.sql.exec(
        `INSERT INTO forwarding_aliases (user_id, alias_nonce, token_hash, created_at, rotated_at)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT (user_id) DO UPDATE SET
           alias_nonce = excluded.alias_nonce,
           token_hash = excluded.token_hash,
           rotated_at = excluded.rotated_at`,
        userId,
        aliasNonce,
        tokenHash,
        now,
        now,
      );
      const record = this.aliasStatus(userId);
      if (record === null) throw new Error("Forwarding alias upsert did not persist");
      return record;
    });
  }

  revokeAlias(userId: string): boolean {
    const before = this.sql.exec<{ count: number }>(
      "SELECT COUNT(*) AS count FROM forwarding_aliases WHERE user_id = ?",
      userId,
    ).toArray()[0]?.count ?? 0;
    this.sql.exec("DELETE FROM forwarding_aliases WHERE user_id = ?", userId);
    return before > 0;
  }

  userIdForTokenHash(tokenHash: string): string | null {
    return this.sql.exec<{ user_id: string }>(
      "SELECT user_id FROM forwarding_aliases WHERE token_hash = ?",
      tokenHash,
    ).toArray()[0]?.user_id ?? null;
  }

  upsertTicket(userId: string, id: string, ticket: ParsedForwardedTicket, now = Date.now()): void {
    this.sql.exec(
      `INSERT INTO forwarded_tickets
         (id, user_id, message_key, subject, sender, received_at, operator_name, train_number,
          origin_name, destination_name, departure_time, arrival_time, booking_reference,
          passenger_name, coach, seat, artifact_mime_type, artifact_filename, artifact_data, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (user_id, message_key) DO UPDATE SET
         subject = excluded.subject, sender = excluded.sender, received_at = excluded.received_at,
         operator_name = excluded.operator_name, train_number = excluded.train_number,
         origin_name = excluded.origin_name, destination_name = excluded.destination_name,
         departure_time = excluded.departure_time, arrival_time = excluded.arrival_time,
         booking_reference = excluded.booking_reference, passenger_name = excluded.passenger_name,
         coach = excluded.coach, seat = excluded.seat, artifact_mime_type = excluded.artifact_mime_type,
         artifact_filename = excluded.artifact_filename, artifact_data = excluded.artifact_data`,
      id,
      userId,
      ticket.messageKey,
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
      ticket.artifact?.mimeType ?? null,
      ticket.artifact?.filename ?? null,
      ticket.artifact?.data ?? null,
      now,
    );
  }

  tickets(userId: string): ForwardedTicketSummary[] {
    return this.sql.exec<TicketRow>(
      `SELECT id, subject, sender, received_at, operator_name, train_number, origin_name, destination_name,
              departure_time, arrival_time, booking_reference, passenger_name, coach, seat, artifact_data
       FROM forwarded_tickets WHERE user_id = ? ORDER BY received_at DESC LIMIT 200`,
      userId,
    ).toArray().map((row) => ({
      id: row.id,
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
      hasArtifact: row.artifact_data !== null,
    }));
  }

  ticketArtifact(userId: string, ticketId: string): ForwardedTicketArtifactDescriptor | null {
    const row = this.sql.exec<{
      artifact_mime_type: string | null;
      artifact_filename: string | null;
      artifact_data: string | null;
    }>(
      "SELECT artifact_mime_type, artifact_filename, artifact_data FROM forwarded_tickets WHERE id = ? AND user_id = ?",
      ticketId,
      userId,
    ).toArray()[0];
    if (row === undefined || row.artifact_data === null || row.artifact_mime_type === null) return null;
    return {
      filename: row.artifact_filename ?? "Train ticket",
      mimeType: row.artifact_mime_type,
      data: row.artifact_data,
    };
  }

  removeTicket(userId: string, ticketId: string): boolean {
    const before = this.sql.exec<{ count: number }>(
      "SELECT COUNT(*) AS count FROM forwarded_tickets WHERE id = ? AND user_id = ?",
      ticketId,
      userId,
    ).toArray()[0]?.count ?? 0;
    this.sql.exec("DELETE FROM forwarded_tickets WHERE id = ? AND user_id = ?", ticketId, userId);
    return before > 0;
  }
}
