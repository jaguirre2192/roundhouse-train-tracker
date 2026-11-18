import type { GmailMessage } from "./gmail-models.js";

interface MessageListResponse { messages?: Array<{ id: string }>; historyId?: string }
interface GmailProfile { emailAddress: string; historyId: string }

const initialSearch = [
  "newer_than:180d",
  "{subject:\"train ticket\" subject:\"rail ticket\" subject:\"booking confirmation\"",
  "subject:\"reservation confirmation\" subject:\"e-ticket\" subject:\"travel document\"",
  "from:trainline.com from:amtrak.com from:sncf-connect.com from:thetrainline.com",
  "from:deutschebahn.com from:bahn.de from:trenitalia.com from:italotreno.com",
  "from:renfe.es from:iryo.eu from:eurostar.com from:nsinternational.com",
  "from:booking@news.omio.com from:booking@omio.com from:cp.pt from:viarail.ca",
  "from:jr-central.co.jp from:westjr.co.jp}",
].join(" ");

export class GmailAPI {
  constructor(private readonly accessToken: string) {}

  profile(): Promise<GmailProfile> {
    return this.get<GmailProfile>("/profile");
  }

  async messageIDs(after: number | null): Promise<{ ids: string[]; historyId: string | null }> {
    const query = after === null
      ? initialSearch
      : `${initialSearch.replace("newer_than:180d", `after:${Math.max(0, Math.floor(after / 1_000) - 86_400)}`)}`;
    const response = await this.get<MessageListResponse>("/messages", {
      q: query,
      // Each returned ID requires a separate full-message request. Keep the
      // complete scan safely below the Worker's external-subrequest ceiling.
      maxResults: "30",
      includeSpamTrash: "false",
    });
    return {
      ids: (response.messages ?? []).map((message) => message.id),
      historyId: response.historyId ?? null,
    };
  }

  message(id: string): Promise<GmailMessage> {
    return this.get<GmailMessage>(`/messages/${encodeURIComponent(id)}`, { format: "full" });
  }

  async attachment(messageId: string, attachmentId: string): Promise<string> {
    const response = await this.get<{ data?: string }>(
      `/messages/${encodeURIComponent(messageId)}/attachments/${encodeURIComponent(attachmentId)}`,
    );
    if (response.data === undefined) throw new Error("Gmail attachment had no data");
    return response.data;
  }

  async watch(topicName: string): Promise<{ historyId: string; expiration: string }> {
    const response = await fetch("https://gmail.googleapis.com/gmail/v1/users/me/watch", {
      method: "POST",
      headers: this.headers({ "content-type": "application/json" }),
      body: JSON.stringify({ topicName, labelIds: ["INBOX"], labelFilterBehavior: "include" }),
    });
    if (!response.ok) throw new Error(`Gmail watch failed (${response.status})`);
    return await response.json() as { historyId: string; expiration: string };
  }

  private async get<Response>(path: string, query: Record<string, string> = {}): Promise<Response> {
    const url = new URL(`https://gmail.googleapis.com/gmail/v1/users/me${path}`);
    url.search = new URLSearchParams(query).toString();
    const response = await fetch(url, { headers: this.headers() });
    if (!response.ok) throw new Error(`Gmail API request failed (${response.status})`);
    return await response.json() as Response;
  }

  private headers(additional: Record<string, string> = {}): Record<string, string> {
    return { authorization: `Bearer ${this.accessToken}`, accept: "application/json", ...additional };
  }
}
