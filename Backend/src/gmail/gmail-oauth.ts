interface TokenResponse {
  access_token: string;
  expires_in: number;
  refresh_token?: string;
  scope: string;
  token_type: string;
}

export interface GmailOAuthConfiguration {
  clientId: string;
  clientSecret: string;
  redirectURI: string;
}

export function gmailAuthorizationURL(
  configuration: GmailOAuthConfiguration,
  state: string,
  codeChallenge: string,
): URL {
  const url = new URL("https://accounts.google.com/o/oauth2/v2/auth");
  url.search = new URLSearchParams({
    client_id: configuration.clientId,
    redirect_uri: configuration.redirectURI,
    response_type: "code",
    scope: "openid email https://www.googleapis.com/auth/gmail.readonly",
    access_type: "offline",
    prompt: "consent",
    include_granted_scopes: "true",
    state,
    code_challenge: codeChallenge,
    code_challenge_method: "S256",
  }).toString();
  return url;
}

async function tokenRequest(parameters: Record<string, string>): Promise<TokenResponse> {
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(parameters),
  });
  if (!response.ok) throw new Error(`Google OAuth token request failed (${response.status})`);
  return await response.json() as TokenResponse;
}

export function exchangeGmailCode(
  configuration: GmailOAuthConfiguration,
  code: string,
  verifier: string,
): Promise<TokenResponse> {
  return tokenRequest({
    code,
    client_id: configuration.clientId,
    client_secret: configuration.clientSecret,
    redirect_uri: configuration.redirectURI,
    grant_type: "authorization_code",
    code_verifier: verifier,
  });
}

export async function refreshGmailAccessToken(
  configuration: Pick<GmailOAuthConfiguration, "clientId" | "clientSecret">,
  refreshToken: string,
): Promise<string> {
  const token = await tokenRequest({
    refresh_token: refreshToken,
    client_id: configuration.clientId,
    client_secret: configuration.clientSecret,
    grant_type: "refresh_token",
  });
  return token.access_token;
}
