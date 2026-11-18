import { createExecutionContext, env } from "cloudflare:test";
import { expect, it, vi } from "vitest";
import type { ForwardedTicketSummary } from "../src/forwarding/forwarding-models.js";
import worker from "../src/cloudflare/index.js";
import { authorized, createSession } from "./forwarding-session.js";

// An older deployment may still provide this unused environment variable.
const bindings = { ...env, PLUS_FORWARDING_ENFORCED: "true" };

function request(path: string, method: string, token: string, forwardingSecret?: string) {
  const httpRequest = new Request("https://example.test/v1/forwarding/" + path, {
    method, headers: authorized(token),
  });
  const requestBindings = forwardingSecret === undefined ? bindings : { ...bindings, TICKET_FORWARDING_SECRET: forwardingSecret };
  return worker.fetch(httpRequest as Parameters<typeof worker.fetch>[0], requestBindings, createExecutionContext());
}

const attachment = "%PDF-1.4\nsynthetic train ticket\n%%EOF";

async function forwardTicket(address: string) {
  const raw = new Blob([[
    "From: Amtrak <tickets@amtrak.com>",
    "Subject: Your train booking confirmation",
    "MIME-Version: 1.0",
    'Content-Type: multipart/mixed; boundary="ticket"',
    "", "--ticket", "Content-Type: text/plain; charset=utf-8", "",
    "Train 171. Booking reference: TEST171. Coach 3 Seat 12.",
    "--ticket", "Content-Type: application/pdf", 'Content-Disposition: attachment; filename="train.pdf"',
    "Content-Transfer-Encoding: base64", "", btoa(attachment), "--ticket--",
  ].join("\r\n")]);
  const setReject = vi.fn();
  const message = {
    from: "rider@example.test", to: address,
    headers: new Headers({ "message-id": "<train-171@example.test>" }),
    raw: raw.stream(), rawSize: raw.size, setReject,
  } as unknown as ForwardableEmailMessage;
  await worker.email(message, bindings, createExecutionContext());
  return setReject;
}

it("forwards an Amtrak ticket to its owner without a purchase and keeps the ticket after the address is retired", async () => {
  const owner = await createSession("free-forwarding-rider");
  const other = await createSession("another-rider");
  const created = await request("alias", "POST", owner);
  expect(created.status).toBe(200);
  const initial = await created.json() as { address: string };
  const rotated = await request("alias/rotate", "POST", owner);
  expect(rotated.status).toBe(200);
  const { address } = await rotated.json() as { address: string };
  expect(address).not.toBe(initial.address);

  expect(await forwardTicket(initial.address)).toHaveBeenCalledWith("Unrecognized recipient");
  expect(await forwardTicket(address)).not.toHaveBeenCalled();
  expect(await forwardTicket(address)).not.toHaveBeenCalled();
  const tickets = await (await request("tickets", "GET", owner)).json() as ForwardedTicketSummary[];
  expect(tickets).toHaveLength(1);
  expect(tickets[0]).toMatchObject({ trainNumber: "171", bookingReference: "TEST171", hasArtifact: true });
  const ticketPath = "tickets/" + tickets[0]!.id;
  expect(await (await request("tickets", "GET", other)).json()).toEqual([]);
  expect((await request(ticketPath + "/artifact", "GET", other)).status).toBe(404);
  expect((await request(ticketPath, "DELETE", other)).status).toBe(404);

  expect((await request("alias", "DELETE", owner, "")).status).toBe(204);
  expect(await forwardTicket(address)).toHaveBeenCalledWith("Unrecognized recipient");
  const file = await request(ticketPath + "/artifact", "GET", owner, "");
  expect(file.headers.get("content-type")).toBe("application/pdf");
  expect(new Uint8Array(await file.arrayBuffer())).toEqual(new TextEncoder().encode(attachment));
  expect((await request(ticketPath, "DELETE", owner, "")).status).toBe(204);
  expect(await (await request("tickets", "GET", owner)).json()).toEqual([]);
});
