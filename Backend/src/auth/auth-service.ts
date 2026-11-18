import { decryptSecret, encryptSecret } from "../gmail/gmail-crypto.js";
import type { AppUserSummary, GoogleAuthState, VerifiedIdentity } from "./auth-models.js";
import { AuthRepository } from "./auth-repository.js";

export class AuthService {
  private readonly repository: AuthRepository;

  constructor(storage: DurableObjectStorage, private readonly encryptionKey: string) {
    this.repository = new AuthRepository(storage);
  }

  createGoogleState(
    stateHash: string,
    verifier: string,
    transactionId: string,
    appChallenge: string,
    expectedUserId: string | null,
    expiresAt: number,
  ): void {
    this.repository.createGoogleState(
      stateHash,
      verifier,
      transactionId,
      appChallenge,
      expectedUserId,
      expiresAt,
    );
  }

  consumeGoogleState(stateHash: string): GoogleAuthState | null {
    return this.repository.consumeGoogleState(stateHash);
  }

  async resolveIdentity(
    identity: VerifiedIdentity,
    expectedUserId: string | null,
    appleRefreshToken: string | null,
  ): Promise<string | null> {
    const encrypted = appleRefreshToken === null
      ? null
      : await encryptSecret(appleRefreshToken, this.encryptionKey);
    return this.repository.resolveIdentity(identity, expectedUserId, encrypted);
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

  exchangeSession(
    codeHash: string,
    transactionId: string,
    presentedChallenge: string,
    sessionHash: string,
    expiresAt: number,
  ): AppUserSummary | null {
    return this.repository.exchangeSession(
      codeHash,
      transactionId,
      presentedChallenge,
      sessionHash,
      expiresAt,
    );
  }

  createSession(userId: string, sessionHash: string, expiresAt: number): AppUserSummary {
    return this.repository.createSession(userId, sessionHash, expiresAt);
  }

  userIdForSession(sessionHash: string): string | null {
    return this.repository.userIdForSession(sessionHash);
  }

  userForSession(sessionHash: string): AppUserSummary | null {
    return this.repository.userForSession(sessionHash);
  }

  revokeSession(sessionHash: string): void {
    this.repository.revokeSession(sessionHash);
  }

  async appleRefreshCredentials(userId: string) {
    return Promise.all(this.repository.appleRefreshCredentials(userId).map(async (credential) => ({
      clientId: credential.clientId,
      refreshToken: await decryptSecret(credential.encryptedRefreshToken, this.encryptionKey),
    })));
  }

  deleteUser(userId: string): void {
    this.repository.deleteUser(userId);
  }
}
