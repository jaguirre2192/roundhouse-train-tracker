interface GoogleTokenResponse {
  access_token: string;
  expires_in: number;
  id_token: string;
  scope: string;
  token_type: string;
}

export interface GoogleOAuthConfiguration {
  clientId: string;
  clientSecret: string;
  redirectURI: string;
}

export function googleAuthorizationURL(
  configuration: GoogleOAuthConfiguration,
  state: string,
  codeChallenge: string,
): URL {
  const url = new URL("https://accounts.google.com/o/oauth2/v2/auth");
  url.search = new URLSearchParams({
    client_id: configuration.clientId,
    redirect_uri: configuration.redirectURI,
    response_type: "code",
    scope: "openid email profile",
    prompt: "select_account",
    state,
    code_challenge: codeChallenge,
    code_challenge_method: "S256",
  }).toString();
  return url;
}

export async function exchangeGoogleCode(
  configuration: GoogleOAuthConfiguration,
  code: string,
  verifier: string,
): Promise<GoogleTokenResponse> {
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: configuration.clientId,
      client_secret: configuration.clientSecret,
      redirect_uri: configuration.redirectURI,
      grant_type: "authorization_code",
      code_verifier: verifier,
    }),
  });
  if (!response.ok) throw new Error(`Google sign-in token request failed (${response.status})`);
  return await response.json() as GoogleTokenResponse;
}
