import { DenmarkBusError, denmarkOperation, denmarkResponseBytes } from "./denmark-servicebus-request.js";

const tokenURL = "https://login.microsoftonline.com/f1044067-8c60-4022-98d8-69306c5f7238/oauth2/v2.0/token";
export const denmarkServiceBusScope = "https://servicebus.azure.net/.default";

/** Tokens remain memory-only and are renewed from the actual expiry. */
export class DenmarkServiceBusAuth {
  private cached: { token: string; expiresAt: number } | null = null;
  private pending: Promise<string> | null = null;
  constructor(private readonly clientID: string, private readonly clientSecret: string,
    private readonly fetcher: typeof fetch, private readonly now: () => number = () => Date.now()) {}

  invalidate() { this.cached = null; }

  /** Azure's TokenCredential receives the actual OAuth expiry, never a guessed lease. */
  async accessToken(signal?: AbortSignal): Promise<{ token: string; expiresOnTimestamp: number }> {
    await this.token(signal);
    if (this.cached === null) throw new DenmarkBusError("oauth", "invalid-response");
    return { token: this.cached.token, expiresOnTimestamp: this.cached.expiresAt };
  }

  token(signal?: AbortSignal): Promise<string> {
    if (signal?.aborted) return Promise.reject(new DenmarkBusError("oauth", "deadline"));
    if (this.cached !== null && this.cached.expiresAt - this.now() > 60_000) return Promise.resolve(this.cached.token);
    this.pending ??= this.load(signal).finally(() => { this.pending = null; });
    return this.pending;
  }

  private load(parent?: AbortSignal): Promise<string> {
    return denmarkOperation("oauth", parent, 8_000, async (signal) => {
      const response = await this.fetcher(tokenURL, { method: "POST", redirect: "manual", signal,
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ grant_type: "client_credentials", client_id: this.clientID,
          client_secret: this.clientSecret, scope: denmarkServiceBusScope }).toString() });
      if (response.status !== 200) {
        await response.body?.cancel(); throw new DenmarkBusError("oauth", "http", response.status);
      }
      let value: { access_token?: unknown; token_type?: unknown; expires_in?: unknown };
      try { value = JSON.parse(new TextDecoder().decode(await denmarkResponseBytes(response, 64 * 1_024, "oauth"))); }
      catch (error) { if (error instanceof DenmarkBusError) throw error; throw new DenmarkBusError("oauth", "invalid-response"); }
      if (value === null || typeof value.access_token !== "string" || !/^[^\s]{1,16384}$/u.test(value.access_token)
        || value.token_type !== "Bearer" || !Number.isSafeInteger(value.expires_in)
        || Number(value.expires_in) <= 60 || Number(value.expires_in) > 86_400) throw new DenmarkBusError("oauth", "invalid-response");
      this.cached = { token: value.access_token, expiresAt: this.now() + Number(value.expires_in) * 1_000 };
      return value.access_token;
    });
  }
}
