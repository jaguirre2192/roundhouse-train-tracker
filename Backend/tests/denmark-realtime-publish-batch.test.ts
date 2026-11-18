import { describe, expect, it, vi } from "vitest";
import { publishDenmarkBatch } from "../src/cloudflare/denmark-realtime-publish.js";
import { denmarkSiriBatchContentType, denmarkSiriBatchLimits } from "../src/cloudflare/denmark-siri-batch.js";

const signal = () => new AbortController().signal;
const messages = [new TextEncoder().encode("<Siri>DSB København</Siri>"), new TextEncoder().encode("<Siri>regional</Siri>")];
const acknowledgement = { accepted: true, source: "denmark-siri", outcome: "stored", deliveries: 2, ignoredStale: 1 };

describe("durable Denmark batch publication acknowledgement", () => {
  it("preserves the ordered UTF8 deliveries and requires an exact durable batch count", async () => {
    const fetcher: typeof fetch = async (input, init) => {
      expect(String(input)).toBe("https://roundhouse-api.example.invalid/internal/rail-data/denmark-siri");
      expect(init?.redirect).toBe("manual");
      const headers = new Headers(init?.headers);
      expect(headers.get("authorization")).toBe("Bearer fixture-secret");
      expect(headers.get("content-type")).toBe(denmarkSiriBatchContentType);
      expect(JSON.parse(new TextDecoder().decode(init?.body as ArrayBuffer)))
        .toEqual({ deliveries: messages.map(bytes => new TextDecoder().decode(bytes)) });
      return Response.json(acknowledgement);
    };
    expect(await publishDenmarkBatch("fixture-secret", messages, signal(), fetcher)).toEqual({ deliveries: 2, ignoredStale: 1 });
  });

  it.each([
    { deliveries: 1 }, { deliveries: "2" }, { ignoredStale: -1 }, { ignoredStale: 3 },
    { ignoredStale: 0.5 }, { ignoredStale: "1" }, { outcome: "queued" }, { accepted: false }, { source: "other" },
  ])("rejects a mismatched or non-durable ACK: %j", async change => {
    await expect(publishDenmarkBatch("fixture-secret", messages, signal(), async () => Response.json({ ...acknowledgement, ...change })))
      .rejects.toMatchObject({ phase: "publish", code: "invalid-response" });
  });

  it("bounds both message count and aggregate bytes before any request", async () => {
    const fetcher = vi.fn<typeof fetch>();
    for (const values of [[], Array.from({ length: 15 }, () => messages[0]!),
      [new Uint8Array(20 * 1_024 * 1_024 + 1)], [new Uint8Array()]]) {
      await expect(publishDenmarkBatch("fixture-secret", values, signal(), fetcher))
        .rejects.toMatchObject({ phase: "publish", code: "body-limit" });
    }
    await expect(publishDenmarkBatch("fixture-secret", [new Uint8Array([0xff])], signal(), fetcher))
      .rejects.toMatchObject({ phase: "publish", code: "invalid-response" });
    expect(fetcher).not.toHaveBeenCalled();
  });
});
