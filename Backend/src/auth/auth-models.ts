export type AuthProvider = "apple" | "google";

export interface AppUserSummary {
  id: string;
  email: string | null;
  displayName: string | null;
  providers: AuthProvider[];
}

export interface VerifiedIdentity {
  provider: AuthProvider;
  subject: string;
  email: string | null;
  emailVerified: boolean;
  displayName: string | null;
  clientId: string;
}

export interface GoogleAuthState {
  verifier: string;
  transactionId: string;
  appChallenge: string;
  expectedUserId: string | null;
}

export interface AppleRefreshCredential {
  encryptedRefreshToken: string;
  clientId: string;
}
