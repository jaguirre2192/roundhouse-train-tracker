import { createExecutionContext, env, SELF } from "cloudflare:test";
import { runInInitializedWatcher as runInDurableObject } from "./initialized-watcher.js";
import { describe, expect, it } from "vitest";
import worker from "../src/cloudflare/index.js";
import { authorized, createSession } from "./forwarding-session.js";
import type { WorkerEnv } from "../src/cloudflare/env.js";

describe("Forwarding API routes", () => {
  it("requires authentication for every forwarding endpoint", async () => {
    for (const request of [
      new Request("https://example.test/v1/forwarding/alias"),
      new Request("https://example.test/v1/forwarding/alias", { method: "POST" }),
      new Request("https://example.test/v1/forwarding/alias/rotate", { method: "POST" }),
      new Request("https://example.test/v1/forwarding/alias", { method: "DELETE" }),
      new Request("https://example.test/v1/forwarding/tickets"),
    ]) {
      const response = await SELF.fetch(request);
      expect(response.status).toBe(401);
    }
  });

  it("creates, reads status, rotates, and revokes an alias over HTTP", async () => {
    const token = await createSession("route-user-alias");

    const statusBefore = await SELF.fetch("https://example.test/v1/forwarding/alias", { headers: authorized(token) });
    expect(await statusBefore.json()).toEqual({ active: false, address: null, createdAt: null, rotatedAt: null });

    const createResponse = await SELF.fetch("https://example.test/v1/forwarding/alias", {
      method: "POST",
      headers: authorized(token),
    });
    expect(createResponse.status).toBe(200);
    const created = await createResponse.json() as { active: boolean; address: string | null };
    expect(created.active).toBe(true);
    expect(created.address).toMatch(/^tickets\+[0-9a-f]{40}@gettraintracker\.com$/u);

    // GET must re-derive and return the address (e.g. after app reinstall or
    // from a second signed-in device) without ever having stored it raw.
    const statusAfter = await SELF.fetch("https://example.test/v1/forwarding/alias", { headers: authorized(token) });
    const status = await statusAfter.json() as { active: boolean; address: string | null };
    expect(status.active).toBe(true);
    expect(status.address).toBe(created.address);

    const rotateResponse = await SELF.fetch("https://example.test/v1/forwarding/alias/rotate", {
      method: "POST",
      headers: authorized(token),
    });
    const rotated = await rotateResponse.json() as { address: string | null };
    expect(rotated.address).not.toBe(created.address);

    const revokeResponse = await SELF.fetch("https://example.test/v1/forwarding/alias", {
      method: "DELETE",
      headers: authorized(token),
    });
    expect(revokeResponse.status).toBe(204);

    const statusFinal = await SELF.fetch("https://example.test/v1/forwarding/alias", { headers: authorized(token) });
    expect((await statusFinal.json() as { active: boolean }).active).toBe(false);
  });

  it("isolates alias and ticket data between different authenticated users", async () => {
    const tokenA = await createSession("route-user-a");
    const tokenB = await createSession("route-user-b");

    await SELF.fetch("https://example.test/v1/forwarding/alias", { method: "POST", headers: authorized(tokenA) });

    const bStatus = await SELF.fetch("https://example.test/v1/forwarding/alias", { headers: authorized(tokenB) });
    expect((await bStatus.json() as { active: boolean }).active).toBe(false);

    const stubGlobal = env.WATCHER.getByName("global");
    await stubGlobal.importForwardedTicket("route-user-a", {
      messageKey: "route-user-a-msg-1",
      subject: "Your train booking confirmation",
      sender: "tickets@amtrak.com",
      receivedAt: new Date().toISOString(),
      operatorName: "Amtrak",
      trainNumber: "171",
      originName: null,
      destinationName: null,
      departureTime: null,
      arrivalTime: null,
      bookingReference: "XYZ987",
      passengerName: null,
      coach: null,
      seat: null,
      artifact: { filename: "ticket.pdf", mimeType: "application/pdf", data: Buffer.from("%PDF-1.4").toString("base64") },
    });

    const ticketsA = await SELF.fetch("https://example.test/v1/forwarding/tickets", { headers: authorized(tokenA) });
    const listA = await ticketsA.json() as Array<{ id: string; trainNumber: string | null }>;
    expect(listA).toHaveLength(1);
    expect(listA[0]?.trainNumber).toBe("171");
    // The ticket id must be an opaque digest, never the raw user id, even
    // though it still stays scoped to that user (asserted below via the
    // cross-account 404s and the owning account's own 200/204 responses).
    expect(listA[0]?.id).not.toContain("route-user-a");

    const ticketsB = await SELF.fetch("https://example.test/v1/forwarding/tickets", { headers: authorized(tokenB) });
    expect(await ticketsB.json()).toEqual([]);

    const ticketId = listA[0]!.id;
    const crossAccountArtifact = await SELF.fetch(
      `https://example.test/v1/forwarding/tickets/${encodeURIComponent(ticketId)}/artifact`,
      { headers: authorized(tokenB) },
    );
    expect(crossAccountArtifact.status).toBe(404);

    const crossAccountDelete = await SELF.fetch(
      `https://example.test/v1/forwarding/tickets/${encodeURIComponent(ticketId)}`,
      { method: "DELETE", headers: authorized(tokenB) },
    );
    expect(crossAccountDelete.status).toBe(404);

    const ownArtifact = await SELF.fetch(
      `https://example.test/v1/forwarding/tickets/${encodeURIComponent(ticketId)}/artifact`,
      { headers: authorized(tokenA) },
    );
    expect(ownArtifact.status).toBe(200);
    expect(ownArtifact.headers.get("content-type")).toBe("application/pdf");

    const ownDelete = await SELF.fetch(
      `https://example.test/v1/forwarding/tickets/${encodeURIComponent(ticketId)}`,
      { method: "DELETE", headers: authorized(tokenA) },
    );
    expect(ownDelete.status).toBe(204);

    const afterDelete = await SELF.fetch("https://example.test/v1/forwarding/tickets", { headers: authorized(tokenA) });
    expect(await afterDelete.json()).toEqual([]);
  });

  it("deletes forwarding aliases and imported tickets when the account is deleted", async () => {
    const token = await createSession("route-user-deletion");
    await SELF.fetch("https://example.test/v1/forwarding/alias", { method: "POST", headers: authorized(token) });

    const stubGlobal = env.WATCHER.getByName("global");
    await stubGlobal.importForwardedTicket("route-user-deletion", {
      messageKey: "route-user-deletion-msg-1",
      subject: "Your train booking confirmation",
      sender: "tickets@amtrak.com",
      receivedAt: new Date().toISOString(),
      operatorName: "Amtrak",
      trainNumber: "202",
      originName: null,
      destinationName: null,
      departureTime: null,
      arrivalTime: null,
      bookingReference: "DEL123",
      passengerName: null,
      coach: null,
      seat: null,
      artifact: null,
    });

    const deleteResponse = await SELF.fetch("https://example.test/v1/auth/account", {
      method: "DELETE",
      headers: authorized(token),
    });
    expect(deleteResponse.status).toBe(204);

    const rows = await runInDurableObject(stubGlobal, (_instance, state) => ({
      aliases: state.storage.sql.exec(
        "SELECT 1 FROM forwarding_aliases WHERE user_id = ?",
        "route-user-deletion",
      ).toArray(),
      tickets: state.storage.sql.exec(
        "SELECT 1 FROM forwarded_tickets WHERE user_id = ?",
        "route-user-deletion",
      ).toArray(),
    }));
    expect(rows.aliases).toHaveLength(0);
    expect(rows.tickets).toHaveLength(0);
  });

  it("returns a clear 503 contract when TICKET_FORWARDING_SECRET is absent or too short", async () => {
    const authToken = await createSession("route-user-unavailable");
    const context = createExecutionContext();
    for (const ticketForwardingSecret of [undefined, "too-short-secret"]) {
      const request = new Request("https://example.test/v1/forwarding/alias", {
        headers: authorized(authToken),
      }) as unknown as Parameters<typeof worker.fetch>[0];
      const unavailable = await worker.fetch(
        request,
        { WATCHER: env.WATCHER, TICKET_FORWARDING_SECRET: ticketForwardingSecret } as WorkerEnv,
        context,
      );
      expect(unavailable.status).toBe(503);
      expect(await unavailable.json()).toEqual({ error: "service_unavailable" });
    }
  });
});
