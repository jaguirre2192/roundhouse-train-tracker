import { GmailAPI } from "./gmail-api.js";
import { decryptSecret } from "./gmail-crypto.js";
import type {
  GmailConnectResult,
  GmailConnectionSummary,
  GmailManualScanResult,
  GmailOAuthState,
  GmailTicketSummary,
} from "./gmail-models.js";
import { refreshGmailAccessToken } from "./gmail-oauth.js";
import { isRejectedGmailSubject, parseGmailTicket } from "./gmail-parser.js";
import { GmailRepository } from "./gmail-repository.js";

interface GmailServiceConfiguration {
  clientId: string;
  clientSecret: string;
  tokenEncryptionKey: string;
  pubSubTopic: string | null;
}

export class GmailInboxService {
  private readonly repository: GmailRepository;
  private readonly manualScanRequests = new Map<string, Promise<GmailManualScanResult>>();

  constructor(storage: DurableObjectStorage, private readonly configuration: GmailServiceConfiguration) {
    this.repository = new GmailRepository(storage);
  }

  createOAuthState(
    stateHash: string,
    verifier: string,
    linkUserId: string,
    transactionId: string,
    appChallenge: string,
    expiresAt: number,
  ): boolean {
    return this.repository.createOAuthState(
      stateHash,
      verifier,
      linkUserId,
      transactionId,
      appChallenge,
      expiresAt,
    );
  }

  consumeOAuthState(stateHash: string): GmailOAuthState | null {
    return this.repository.consumeOAuthState(stateHash);
  }

  userIdForSession(sessionHash: string): string | null {
    return this.repository.userIdForSession(sessionHash);
  }

  userIdForEmail(emailAddress: string): string | null {
    return this.repository.userIdForEmail(emailAddress);
  }

  connectAccount(
    linkUserId: string,
    emailAddress: string,
    encryptedRefreshToken: string,
    historyId: string | null,
  ): GmailConnectResult {
    return this.repository.connectAccount(linkUserId, emailAddress, encryptedRefreshToken, historyId);
  }

  createExchangeCode(
    codeHash: string,
    userId: string,
    transactionId: string,
    appChallenge: string,
    expiresAt: number,
  ): void {
    this.repository.createExchangeCode(codeHash, userId, transactionId, appChallenge, expiresAt);
  }

  completeConnection(
    codeHash: string,
    transactionId: string,
    presentedChallenge: string,
    authenticatedUserId: string,
  ): boolean {
    return this.repository.completeConnection(
      codeHash,
      transactionId,
      presentedChallenge,
      authenticatedUserId,
    );
  }

  exchangeSession(codeHash: string, sessionHash: string, expiresAt: number): boolean {
    return this.repository.exchangeSession(codeHash, sessionHash, expiresAt);
  }

  connections(userId: string): GmailConnectionSummary[] {
    return this.repository.connections(userId);
  }

  tickets(userId: string): GmailTicketSummary[] {
    return this.repository.tickets(userId);
  }

  disconnectAccount(userId: string, accountId: string): void {
    this.repository.disconnectAccount(userId, accountId);
  }

  async scanUser(userId: string, fullScan = false): Promise<number> {
    let found = 0;
    for (const account of this.repository.accountsForUser(userId)) {
      try { found += await this.scanAccount(account.id, fullScan); } catch (error) {
        console.error("Gmail account scan failed", { accountId: account.id, error });
      }
    }
    return found;
  }

  scanUserManual(userId: string): Promise<GmailManualScanResult> {
    const existing = this.manualScanRequests.get(userId);
    if (existing !== undefined) return existing;
    const admission = this.repository.beginManualScan(userId);
    if (!admission.accepted) {
      return Promise.resolve({ status: "cooldown", retryAfter: admission.retryAfter });
    }
    const request = this.scanUser(userId, true)
      .then((imported): GmailManualScanResult => ({ status: "completed", imported }))
      .finally(() => {
        this.repository.finishManualScan(userId);
        this.manualScanRequests.delete(userId);
      });
    this.manualScanRequests.set(userId, request);
    return request;
  }

  async scanEmail(emailAddress: string): Promise<number> {
    const account = this.repository.accountForEmail(emailAddress);
    return account === null ? 0 : this.scanAccount(account.id);
  }

  async scanDue(): Promise<number> {
    let found = 0;
    for (const account of this.repository.dueAccounts()) {
      try { found += await this.scanAccount(account.id); } catch (error) {
        console.error("Scheduled Gmail account scan failed", { accountId: account.id, error });
      }
    }
    return found;
  }

  async artifact(userId: string, ticketId: string): Promise<{
    data: string;
    filename: string;
    mimeType: string;
  } | null> {
    const descriptor = this.repository.ticketArtifact(userId, ticketId);
    if (descriptor === null || descriptor.artifact.attachmentId === null) return null;
    const api = await this.api(descriptor.account.encryptedRefreshToken);
    return {
      data: await api.attachment(descriptor.messageId, descriptor.artifact.attachmentId),
      filename: descriptor.artifact.filename,
      mimeType: descriptor.artifact.mimeType,
    };
  }

  private async scanAccount(accountId: string, fullScan = false): Promise<number> {
    const resolved = this.repository.accountById(accountId);
    if (resolved === null) return 0;
    try {
      // Manual refresh is also a reconciliation pass. Remove previously
      // imported messages that are now known to be account, loyalty, or policy
      // mail even when they are older than Gmail's bounded candidate window.
      if (fullScan) {
        this.repository.removeTicketsMatchingSubjects(resolved.id, isRejectedGmailSubject);
      }
      const api = await this.api(resolved.encryptedRefreshToken);
      const messages = await api.messageIDs(fullScan ? null : resolved.lastScanAt);
      let found = 0;
      for (const id of messages.ids) {
        const ticket = parseGmailTicket(await api.message(id));
        if (ticket === null) {
          this.repository.removeTicket(resolved.id, id);
          continue;
        }
        this.repository.upsertTicket(resolved.id, ticket);
        found += 1;
      }
      let historyId = messages.historyId;
      if (this.configuration.pubSubTopic !== null
        && (resolved.watchExpiresAt ?? 0) < Date.now() + 24 * 60 * 60_000) {
        try {
          const watch = await api.watch(this.configuration.pubSubTopic);
          historyId = watch.historyId;
          this.repository.recordWatch(resolved.id, watch.historyId, Number(watch.expiration));
        } catch (error) {
          console.warn("Gmail watch registration failed; scheduled scanning remains active", error);
        }
      }
      this.repository.recordScan(resolved.id, historyId, null);
      return found;
    } catch (error) {
      this.repository.recordScan(
        resolved.id,
        resolved.historyId,
        error instanceof Error ? error.message.slice(0, 500) : String(error).slice(0, 500),
      );
      throw error;
    }
  }

  private async api(encryptedRefreshToken: string): Promise<GmailAPI> {
    const refreshToken = await decryptSecret(encryptedRefreshToken, this.configuration.tokenEncryptionKey);
    const accessToken = await refreshGmailAccessToken(this.configuration, refreshToken);
    return new GmailAPI(accessToken);
  }
}
