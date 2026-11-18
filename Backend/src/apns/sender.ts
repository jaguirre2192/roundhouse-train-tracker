import { createSign } from "node:crypto";
import { connect, constants, type ClientHttp2Session } from "node:http2";
import { makeAPNsPayload } from "./payload.js";
import {
  APNsError,
  pushCollapseId,
  pushExpirationSeconds,
  type PushMessage,
  type PushSender,
} from "./transport.js";

export { APNsError, type PushMessage, type PushSender } from "./transport.js";

export class DryRunPushSender implements PushSender {
  constructor(private readonly log: (entry: object) => void = console.info) {}

  async send(message: PushMessage): Promise<void> {
    this.log({ mode: "dry-run", tokenSuffix: message.token.slice(-8), payload: makeAPNsPayload(message.event) });
  }
}

interface APNsSenderConfig {
  teamId: string;
  keyId: string;
  topics: Record<PushMessage["platform"], string>;
  privateKey: string;
}

function base64url(value: string | Buffer): string {
  return Buffer.from(value).toString("base64url");
}

export class LiveAPNsSender implements PushSender {
  private token: { value: string; issuedAt: number } | null = null;
  private readonly sessions = new Map<PushMessage["environment"], ClientHttp2Session>();

  constructor(private readonly config: APNsSenderConfig) {}

  async send(message: PushMessage): Promise<void> {
    await this.sendOnSession(this.session(message.environment), message);
  }

  private async sendOnSession(client: ClientHttp2Session, message: PushMessage): Promise<void> {
    const body = JSON.stringify(makeAPNsPayload(message.event));
    if (Buffer.byteLength(body) > 4_096) throw new APNsError(413, "PayloadTooLarge");

    await new Promise<void>((resolve, reject) => {
      const request = client.request({
        [constants.HTTP2_HEADER_METHOD]: "POST",
        [constants.HTTP2_HEADER_PATH]: `/3/device/${message.token}`,
        authorization: `bearer ${this.providerToken()}`,
        "apns-topic": this.config.topics[message.platform],
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": String(pushExpirationSeconds(message)),
        // Match the Worker: one collapse identity per material event, so two
        // different alerts for the same trip never replace each other.
        "apns-collapse-id": pushCollapseId(message.event),
      });

      let status = 0;
      let responseBody = "";
      request.setEncoding("utf8");
      request.on("response", (headers) => {
        status = Number(headers[constants.HTTP2_HEADER_STATUS] ?? 0);
      });
      request.on("data", (chunk: string) => { responseBody += chunk; });
      request.on("error", reject);
      request.on("end", () => {
        if (status === 200) return resolve();
        let reason = "Unknown";
        try {
          const parsed = JSON.parse(responseBody) as { reason?: string };
          reason = parsed.reason ?? reason;
        } catch { /* APNs may close without a JSON body. */ }
        reject(new APNsError(status, reason));
      });
      request.end(body);
    });
  }

  private providerToken(): string {
    const now = Math.floor(Date.now() / 1_000);
    if (this.token !== null && now - this.token.issuedAt < 20 * 60) return this.token.value;

    const header = base64url(JSON.stringify({ alg: "ES256", kid: this.config.keyId }));
    const claims = base64url(JSON.stringify({ iss: this.config.teamId, iat: now }));
    const unsigned = `${header}.${claims}`;
    const signer = createSign("SHA256");
    signer.update(unsigned);
    signer.end();
    const signature = signer.sign({ key: this.config.privateKey, dsaEncoding: "ieee-p1363" });
    const value = `${unsigned}.${base64url(signature)}`;
    this.token = { value, issuedAt: now };
    return value;
  }

  private session(environment: PushMessage["environment"]): ClientHttp2Session {
    const existing = this.sessions.get(environment);
    if (existing !== undefined && !existing.closed && !existing.destroyed) return existing;

    const host = environment === "production"
      ? "https://api.push.apple.com"
      : "https://api.sandbox.push.apple.com";
    const client = connect(host);
    this.sessions.set(environment, client);
    const remove = () => {
      if (this.sessions.get(environment) === client) this.sessions.delete(environment);
    };
    client.on("error", remove);
    client.on("close", remove);
    client.on("goaway", () => {
      remove();
      client.close();
    });
    return client;
  }
}
