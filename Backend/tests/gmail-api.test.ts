import { afterEach, describe, expect, it, vi } from "vitest";
import { GmailAPI } from "../src/gmail/gmail-api.js";

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("Gmail candidate search", () => {
  it("uses a narrow query and caps full-message fetches below the Worker subrequest limit", async () => {
    const fetch = vi.fn(async (_input: string | URL | Request) => new Response(JSON.stringify({
      messages: Array.from({ length: 30 }, (_, index) => ({ id: `message-${index}` })),
      historyId: "123",
    }), { status: 200 }));
    vi.stubGlobal("fetch", fetch);

    const result = await new GmailAPI("access-token").messageIDs(null);

    expect(result.ids).toHaveLength(30);
    const url = new URL(String(fetch.mock.calls[0]?.[0]));
    expect(url.searchParams.get("maxResults")).toBe("30");
    expect(url.searchParams.get("includeSpamTrash")).toBe("false");
    expect(url.searchParams.get("q")).not.toContain("subject:train ");
    expect(url.searchParams.get("q")).not.toContain("subject:journey");
    expect(url.searchParams.get("q")).toContain('subject:"train ticket"');
    expect(url.searchParams.get("q")).toContain('subject:"booking confirmation"');
    expect(url.searchParams.get("q")).toContain("from:booking@news.omio.com");
    expect(url.searchParams.get("q")).not.toContain("from:news.omio.com");
  });
});
