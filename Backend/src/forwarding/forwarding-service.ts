import { sha256 } from "../gmail/gmail-crypto.js";
import { deriveAliasToken, randomAliasNonce } from "./forwarding-crypto.js";
import type { ForwardedTicketArtifactDescriptor, ForwardingAliasRecord } from "./forwarding-repository.js";
import { ForwardingRepository } from "./forwarding-repository.js";
import type { ForwardedTicketSummary, ForwardingAliasStatus, ParsedForwardedTicket } from "./forwarding-models.js";

export interface ForwardingServiceConfiguration {
  domain: string;
  secret: string;
}

function inactiveStatus(): ForwardingAliasStatus {
  return { active: false, address: null, createdAt: null, rotatedAt: null };
}

export class ForwardingService {
  private readonly repository: ForwardingRepository;

  constructor(storage: DurableObjectStorage, private readonly configuration: ForwardingServiceConfiguration | null) {
    this.repository = new ForwardingRepository(storage);
  }

  async aliasStatus(userId: string): Promise<ForwardingAliasStatus> {
    const record = this.repository.aliasStatus(userId);
    return record === null ? inactiveStatus() : this.toStatus(userId, record);
  }

  async createAlias(userId: string): Promise<ForwardingAliasStatus> {
    const existing = this.repository.aliasStatus(userId);
    if (existing !== null) return this.toStatus(userId, existing);
    return this.rotateAlias(userId);
  }

  async rotateAlias(userId: string): Promise<ForwardingAliasStatus> {
    if (!this.configuration) throw new Error("Forwarding address configuration unavailable");
    const nonce = randomAliasNonce();
    const token = await deriveAliasToken(this.configuration.secret, nonce, userId, this.configuration.domain);
    const tokenHash = await sha256(token);
    const record = this.repository.upsertAlias(userId, nonce, tokenHash);
    return this.toStatus(userId, record);
  }

  revokeAlias(userId: string): boolean {
    return this.repository.revokeAlias(userId);
  }

  userIdForTokenHash(tokenHash: string): string | null {
    return this.repository.userIdForTokenHash(tokenHash);
  }

  async importTicket(userId: string, ticket: ParsedForwardedTicket, aliasHash?: string): Promise<boolean> {
    const id = await sha256(`${userId}:${ticket.messageKey}`);
    if (id.includes(userId)) throw new Error("Forwarded ticket id must not embed the raw user id");
    // The address can be rotated while an incoming message is being read or parsed.
    if (aliasHash !== undefined && this.repository.userIdForTokenHash(aliasHash) !== userId) return false;
    this.repository.upsertTicket(userId, id, ticket);
    return true;
  }

  tickets(userId: string): ForwardedTicketSummary[] {
    return this.repository.tickets(userId);
  }

  artifact(userId: string, ticketId: string): ForwardedTicketArtifactDescriptor | null {
    return this.repository.ticketArtifact(userId, ticketId);
  }

  deleteTicket(userId: string, ticketId: string): boolean {
    return this.repository.removeTicket(userId, ticketId);
  }

  private async toStatus(userId: string, record: ForwardingAliasRecord): Promise<ForwardingAliasStatus> {
    if (!this.configuration) throw new Error("Forwarding address configuration unavailable");
    const token = await deriveAliasToken(
      this.configuration.secret,
      record.aliasNonce,
      userId,
      this.configuration.domain,
    );
    return {
      active: true,
      address: `tickets+${token}@${this.configuration.domain}`,
      createdAt: new Date(record.createdAt).toISOString(),
      rotatedAt: new Date(record.rotatedAt).toISOString(),
    };
  }
}
