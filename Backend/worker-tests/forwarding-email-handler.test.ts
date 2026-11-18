import { createExecutionContext, env } from "cloudflare:test";
import { runInInitializedWatcher as runInDurableObject } from "./initialized-watcher.js";
import { describe, expect, it, vi } from "vitest";
import worker from "../src/cloudflare/index.js";
import { failsSenderAuthentication } from "../src/cloudflare/forwarding-email-handler.js";
import { forwardingDomain, parseAliasToken } from "../src/cloudflare/forwarding-config.js";
import type { WorkerEnv } from "../src/cloudflare/env.js";

describe("forwarding recipient parsing", () => {
  const domain = "gettraintracker.com";

  it("accepts a well-formed tickets+<token> subaddress regardless of relay case-folding", () => {
    const token = "a".repeat(40);
    expect(parseAliasToken(`tickets+${token}@${domain}`, domain)).toBe(token);
    expect(parseAliasToken(`TICKETS+${token.toUpperCase()}@${domain.toUpperCase()}`, domain)).toBe(token);
  });

  it("rejects recipients on the wrong domain, a subdomain, or with malformed local-parts", () => {
    const token = "b".repeat(40);
    expect(parseAliasToken(`tickets+${token}@example.com`, domain)).toBeNull();
    expect(parseAliasToken(`tickets+${token}@mail.${domain}`, domain)).toBeNull();
    expect(parseAliasToken(`tickets+${token}@tickets.${domain}`, domain)).toBeNull();
    expect(parseAliasToken(`not-a-token@${domain}`, domain)).toBeNull();
    expect(parseAliasToken(`${token}@${domain}`, domain)).toBeNull();
    expect(parseAliasToken(`tickets+${token.slice(0, 39)}@${domain}`, domain)).toBeNull();
    expect(parseAliasToken("no-at-sign", domain)).toBeNull();
  });

  it("falls back to the documented root-domain default when unconfigured", () => {
    expect(forwardingDomain({} as WorkerEnv)).toBe("gettraintracker.com");
    expect(forwardingDomain({ TICKET_FORWARDING_DOMAIN: "custom.example.com" } as WorkerEnv)).toBe("custom.example.com");
  });

  it("flags DMARC authentication failures as spammy", () => {
    expect(failsSenderAuthentication(new Headers({ "Authentication-Results": "mx.example.com; dmarc=fail" }))).toBe(true);
    expect(failsSenderAuthentication(new Headers({ "Authentication-Results": "mx.example.com; dmarc=pass" }))).toBe(false);
    expect(failsSenderAuthentication(new Headers())).toBe(false);
  });
});

interface FakeMessage {
  to: string;
  from: string;
  raw: ReadableStream<Uint8Array>;
  rawSize: number;
  headers: Headers;
  setReject: ReturnType<typeof vi.fn>;
  forward: ReturnType<typeof vi.fn>;
  reply: ReturnType<typeof vi.fn>;
}

function fakeMessage(to: string, headerEntries: Record<string, string>, body: string): FakeMessage {
  const bytes = new TextEncoder().encode(body);
  return {
    to,
    from: "rider@example.com",
    raw: new ReadableStream({
      start(controller) {
        controller.enqueue(bytes);
        controller.close();
      },
    }),
    rawSize: bytes.byteLength,
    headers: new Headers(headerEntries),
    setReject: vi.fn(),
    forward: vi.fn(),
    reply: vi.fn(),
  };
}

async function seedAlias(userId: string): Promise<string> {
  const stub = env.WATCHER.getByName("global");
  await runInDurableObject(stub, (_instance, state) => {
    state.storage.sql.exec("INSERT OR IGNORE INTO gmail_users (id, created_at) VALUES (?, ?)", userId, Date.now());
  });
  const created = await stub.createForwardingAlias(userId);
  return (created.address ?? "").split("@")[0]?.replace(/^tickets\+/u, "") ?? "";
}

describe("forwarded email handler", () => {
  it("rejects mail addressed to an unrecognized recipient without touching storage", async () => {
    const message = fakeMessage("not-a-token@gettraintracker.com", {}, "irrelevant");
    const ctx = createExecutionContext();
    await worker.email!(message as unknown as ForwardableEmailMessage, env, ctx);
    expect(message.setReject).toHaveBeenCalledWith("Unrecognized recipient");
  });

  it("rejects oversized messages before reading the body", async () => {
    const token = await seedAlias("user-oversized");
    const message = fakeMessage(`tickets+${token}@gettraintracker.com`, {}, "irrelevant");
    message.rawSize = 20_000_000;
    const ctx = createExecutionContext();
    await worker.email!(message as unknown as ForwardableEmailMessage, env, ctx);
    expect(message.setReject).toHaveBeenCalledWith("Message too large");
  });

  it("rejects mail that fails DMARC without importing anything", async () => {
    const token = await seedAlias("user-dmarc");
    const message = fakeMessage(
      `tickets+${token}@gettraintracker.com`,
      { "Authentication-Results": "mx.example.com; dmarc=fail" },
      "Train 171. Booking reference: XYZ987.",
    );
    const ctx = createExecutionContext();
    await worker.email!(message as unknown as ForwardableEmailMessage, env, ctx);
    expect(message.setReject).toHaveBeenCalledWith("Message failed sender authentication");
    const tickets = await env.WATCHER.getByName("global").forwardingTickets("user-dmarc");
    expect(tickets).toHaveLength(0);
  });

  it("rejects mail cleanly when forwarding is unconfigured, without crashing the handler", async () => {
    const message = fakeMessage("tickets+not-checked@gettraintracker.com", {}, "irrelevant");
    const ctx = createExecutionContext();
    await worker.email!(
      message as unknown as ForwardableEmailMessage,
      { WATCHER: env.WATCHER } as WorkerEnv,
      ctx,
    );
    expect(message.setReject).toHaveBeenCalledWith("Forwarding is temporarily unavailable");
  });

  it("imports a high-confidence ticket forwarded to a valid alias without leaking secrets in logs", async () => {
    const token = await seedAlias("user-import");
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const body = [
      "From: Amtrak <tickets@amtrak.com>",
      "Subject: Your train booking confirmation",
      "Message-ID: <abc123@amtrak.com>",
      "Content-Type: text/plain; charset=utf-8",
      "",
      "Train 171. Booking reference: XYZ987. Coach 3 Seat 12.",
    ].join("\r\n");
    const message = fakeMessage(`tickets+${token}@gettraintracker.com`, {}, body);
    message.headers.set("message-id", "<abc123@amtrak.com>");
    const ctx = createExecutionContext();

    await worker.email!(message as unknown as ForwardableEmailMessage, env, ctx);

    expect(message.setReject).not.toHaveBeenCalled();
    const tickets = await env.WATCHER.getByName("global").forwardingTickets("user-import");
    expect(tickets).toHaveLength(1);
    expect(tickets[0]).toMatchObject({ trainNumber: "171", bookingReference: "XYZ987" });

    for (const call of errorSpy.mock.calls) {
      const serialized = JSON.stringify(call);
      expect(serialized).not.toContain(token);
      expect(serialized).not.toContain("XYZ987");
      expect(serialized).not.toContain(body);
    }
    errorSpy.mockRestore();
  });

  it("silently drops low-confidence forwards without rejecting or storing them", async () => {
    const token = await seedAlias("user-lowconf");
    const body = "Weekly newsletter with gardening tips.";
    const message = fakeMessage(`tickets+${token}@gettraintracker.com`, {}, [
      "From: newsletter@example.com",
      "Subject: Weekly recipes and garden ideas",
      "Content-Type: text/plain; charset=utf-8",
      "",
      body,
    ].join("\r\n"));
    const ctx = createExecutionContext();

    await worker.email!(message as unknown as ForwardableEmailMessage, env, ctx);

    expect(message.setReject).not.toHaveBeenCalled();
    const tickets = await env.WATCHER.getByName("global").forwardingTickets("user-lowconf");
    expect(tickets).toHaveLength(0);
  });

  it("does not collide two same-size Message-ID-less forwards into one stored ticket", async () => {
    const token = await seedAlias("user-samesize");
    const bodyA = [
      "From: Amtrak <tickets@amtrak.com>",
      "Subject: Your train booking confirmation",
      "Content-Type: text/plain; charset=utf-8",
      "",
      "Train 171. Booking reference: AAAA111. Coach 3 Seat 12.",
    ].join("\r\n");
    const bodyB = [
      "From: Amtrak <tickets@amtrak.com>",
      "Subject: Your train booking confirmation",
      "Content-Type: text/plain; charset=utf-8",
      "",
      "Train 172. Booking reference: BBBB111. Coach 3 Seat 12.",
    ].join("\r\n");
    expect(bodyA.length).toBe(bodyB.length);

    const ctx = createExecutionContext();
    await worker.email!(
      fakeMessage(`tickets+${token}@gettraintracker.com`, {}, bodyA) as unknown as ForwardableEmailMessage,
      env,
      ctx,
    );
    await worker.email!(
      fakeMessage(`tickets+${token}@gettraintracker.com`, {}, bodyB) as unknown as ForwardableEmailMessage,
      env,
      ctx,
    );

    const tickets = await env.WATCHER.getByName("global").forwardingTickets("user-samesize");
    expect(tickets).toHaveLength(2);
    expect(tickets.map((ticket) => ticket.bookingReference).sort()).toEqual(["AAAA111", "BBBB111"]);
  });
});
