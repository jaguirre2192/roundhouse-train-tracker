import type {
  GmailAccountSecret,
  GmailConnectResult,
  GmailConnectionSummary,
  GmailOAuthState,
  GmailTicketSummary,
  ParsedGmailTicket,
} from "./gmail-models.js";
import { GmailAccountStore } from "./gmail-account-store.js";
import { GmailOAuthStore } from "./gmail-oauth-store.js";
import { GmailTicketStore, type GmailTicketArtifactDescriptor } from "./gmail-ticket-store.js";

export class GmailRepository {
  private readonly oauth: GmailOAuthStore;
  private readonly accounts: GmailAccountStore;
  private readonly ticketsStore: GmailTicketStore;

  constructor(storage: DurableObjectStorage) {
    this.oauth = new GmailOAuthStore(storage);
    this.accounts = new GmailAccountStore(storage);
    this.ticketsStore = new GmailTicketStore(storage.sql);
  }

  createOAuthState(
    stateHash: string,
    verifier: string,
    linkUserId: string,
    transactionId: string,
    appChallenge: string,
    expiresAt: number,
    now = Date.now(),
  ): boolean {
    return this.oauth.createState(
      stateHash,
      verifier,
      linkUserId,
      transactionId,
      appChallenge,
      expiresAt,
      now,
    );
  }

  consumeOAuthState(stateHash: string, now = Date.now()): GmailOAuthState | null {
    return this.oauth.consumeState(stateHash, now);
  }

  userIdForSession(sessionHash: string, now = Date.now()): string | null {
    return this.oauth.userIdForSession(sessionHash, now);
  }

  userIdForEmail(emailAddress: string): string | null {
    return this.accounts.userIdForEmail(emailAddress);
  }

  connectAccount(
    linkUserId: string,
    emailAddress: string,
    encryptedRefreshToken: string,
    historyId: string | null,
    now = Date.now(),
  ): GmailConnectResult {
    return this.accounts.connect(linkUserId, emailAddress, encryptedRefreshToken, historyId, now);
  }

  createExchangeCode(
    codeHash: string,
    userId: string,
    transactionId: string,
    appChallenge: string,
    expiresAt: number,
  ): void {
    this.oauth.createExchangeCode(codeHash, userId, transactionId, appChallenge, expiresAt);
  }

  completeConnection(
    codeHash: string,
    transactionId: string,
    presentedChallenge: string,
    authenticatedUserId: string,
    now = Date.now(),
  ): boolean {
    return this.oauth.completeConnection(
      codeHash,
      transactionId,
      presentedChallenge,
      authenticatedUserId,
      now,
    );
  }

  exchangeSession(
    codeHash: string,
    sessionHash: string,
    sessionExpiresAt: number,
    now = Date.now(),
  ): boolean {
    return this.oauth.exchangeSession(codeHash, sessionHash, sessionExpiresAt, now);
  }

  beginManualScan(
    userId: string,
    now = Date.now(),
    cooldownMilliseconds = 10 * 60_000,
    leaseMilliseconds = 2 * 60_000,
  ): { accepted: boolean; retryAfter: number } {
    return this.accounts.beginManualScan(userId, now, cooldownMilliseconds, leaseMilliseconds);
  }

  finishManualScan(userId: string, now = Date.now()): void {
    this.accounts.finishManualScan(userId, now);
  }

  accountsForUser(userId: string): GmailAccountSecret[] {
    return this.accounts.forUser(userId);
  }

  accountForEmail(emailAddress: string): GmailAccountSecret | null {
    return this.accounts.forEmail(emailAddress);
  }

  accountById(accountId: string): GmailAccountSecret | null {
    return this.accounts.byId(accountId);
  }

  dueAccounts(now = Date.now()): GmailAccountSecret[] {
    return this.accounts.due(now);
  }

  connections(userId: string): GmailConnectionSummary[] {
    return this.accounts.connections(userId);
  }

  recordScan(accountId: string, historyId: string | null, error: string | null, now = Date.now()): void {
    this.accounts.recordScan(accountId, historyId, error, now);
  }

  recordWatch(accountId: string, historyId: string, expiresAt: number): void {
    this.accounts.recordWatch(accountId, historyId, expiresAt);
  }

  upsertTicket(accountId: string, ticket: ParsedGmailTicket, now = Date.now()): void {
    this.ticketsStore.upsert(accountId, ticket, now);
  }

  removeTicket(accountId: string, messageId: string): void {
    this.ticketsStore.remove(accountId, messageId);
  }

  removeTicketsMatchingSubjects(
    accountId: string,
    predicate: (subject: string) => boolean,
  ): number {
    return this.ticketsStore.removeMatchingSubjects(accountId, predicate);
  }

  tickets(userId: string): GmailTicketSummary[] {
    return this.ticketsStore.forUser(userId);
  }

  ticketArtifact(userId: string, ticketId: string): GmailTicketArtifactDescriptor | null {
    return this.ticketsStore.artifact(userId, ticketId);
  }

  disconnectAccount(userId: string, accountId: string): void {
    this.accounts.disconnect(userId, accountId);
  }
}
