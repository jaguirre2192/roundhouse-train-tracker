import { describe, expect, it } from "vitest";
import { parseForwardedTicket } from "../src/forwarding/forwarding-mime-parser.js";

function rawMessage(headers: Record<string, string>, body: string): ArrayBuffer {
  const lines = Object.entries(headers).map(([name, value]) => `${name}: ${value}`);
  const source = `${lines.join("\r\n")}\r\n\r\n${body}`;
  return new TextEncoder().encode(source).buffer as ArrayBuffer;
}

interface TestAttachment { filename: string; mimeType: string; base64: string }

function multipartMessage(
  headers: Record<string, string>,
  textBody: string,
  attachment: TestAttachment | TestAttachment[] | null,
): ArrayBuffer {
  const boundary = "ticket-boundary-42";
  const parts = [
    `--${boundary}\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n${textBody}\r\n`,
  ];
  const attachments = attachment === null ? [] : Array.isArray(attachment) ? attachment : [attachment];
  for (const item of attachments) {
    parts.push(
      `--${boundary}\r\nContent-Type: ${item.mimeType}\r\nContent-Disposition: attachment; filename="${item.filename}"\r\nContent-Transfer-Encoding: base64\r\n\r\n${item.base64}\r\n`,
    );
  }
  parts.push(`--${boundary}--`);
  const lines = Object.entries({
    ...headers,
    "Content-Type": `multipart/mixed; boundary="${boundary}"`,
  }).map(([name, value]) => `${name}: ${value}`);
  const source = `${lines.join("\r\n")}\r\n\r\n${parts.join("\r\n")}`;
  return new TextEncoder().encode(source).buffer as ArrayBuffer;
}

describe("Forwarded ticket MIME parsing", () => {
  it("extracts ticket fields from a plain-text rail confirmation", async () => {
    const raw = rawMessage(
      { From: "Trainline <tickets@trainline.com>", Subject: "Your train ticket to Paris" },
      "London St Pancras to Paris Gare du Nord. Train 9032. Booking reference: ABC123. Coach 7 Seat 42.",
    );

    const ticket = await parseForwardedTicket(raw, "message-key-1");
    expect(ticket).toMatchObject({
      operatorName: "Trainline",
      trainNumber: "9032",
      bookingReference: "ABC123",
      coach: "7",
      seat: "42",
      artifact: null,
    });
    expect(JSON.stringify(ticket)).not.toContain("London St Pancras to Paris Gare du Nord. Train");
  });

  it("rejects messages that are not high-confidence rail tickets", async () => {
    const raw = rawMessage(
      { From: "newsletter@example.com", Subject: "Weekly recipes and garden ideas" },
      "Check out this week's recipes and gardening tips.",
    );
    expect(await parseForwardedTicket(raw, "message-key-2")).toBeNull();
  });

  it("rejects known non-ticket subjects even when the body mentions rail terms", async () => {
    const raw = rawMessage(
      { From: "loyalty@trainline.com", Subject: "Your Classique membership has been renewed" },
      "Thanks for being a loyal rail customer. Your membership benefits continue.",
    );
    expect(await parseForwardedTicket(raw, "message-key-3")).toBeNull();
  });

  it.each([
    {
      id: "amtrak-service-advisory",
      subject: "Service advisory for Northeast Regional Train 171",
      sender: "Amtrak Service Alerts <service@e-mail.amtrak.com>",
      body: "Service advisory: Train 171 may operate on a modified schedule.\nDate: 14/09/2026\nFrom: New York Penn Station\nTo: Washington Union Station\nCheck Amtrak.com before you travel.",
    },
    {
      id: "amtrak-delay-update",
      subject: "Delay update: Train 171",
      sender: "Amtrak Service Alerts <service@e-mail.amtrak.com>",
      body: "Train 171 is currently delayed by 45 minutes.\nDate: 14/09/2026\nFrom: New York Penn Station\nTo: Washington Union Station\nThis operational update applies to all passengers.",
    },
    {
      id: "amtrak-cancellation",
      subject: "Train 171 cancellation",
      sender: "Amtrak Service Alerts <service@e-mail.amtrak.com>",
      body: "Train 171 has been cancelled because of severe weather.\nDate: 14/09/2026\nFrom: New York Penn Station\nTo: Washington Union Station\nVisit Amtrak.com for service information.",
    },
    {
      id: "amtrak-loyalty-marketing",
      subject: "Earn double points aboard Train 171",
      sender: "Amtrak Guest Rewards <rewards@e-mail.amtrak.com>",
      body: "Amtrak Guest Rewards members can earn double points when they travel on Train 171. Explore this limited-time offer.",
    },
  ])("rejects an operator non-ticket message even when it names a train: $id", async ({ id, subject, sender, body }) => {
    const raw = rawMessage({ From: sender, Subject: subject }, body);
    expect(await parseForwardedTicket(raw, `message-key-${id}`)).toBeNull();
  });

  it("accepts a genuine no-PNR ticket with dated route and ownership evidence", async () => {
    const raw = rawMessage(
      { From: "Amtrak <tickets@amtrak.com>", Subject: "Your Amtrak travel details" },
      [
        "Passenger: Alex Rivera",
        "Date: 14/09/2026",
        "From: New York Penn Station",
        "To: Washington Union Station",
        "Train 171",
        "Coach 4",
        "Seat 12A",
      ].join("\n"),
    );

    expect(await parseForwardedTicket(raw, "message-key-amtrak-no-pnr-ticket")).toMatchObject({
      trainNumber: "171",
      bookingReference: null,
      passengerName: "Alex Rivera",
      originName: "New York Penn Station",
      destinationName: "Washington Union Station",
      departureTime: "2026-09-14",
      coach: "4",
      seat: "12A",
    });
  });

  it("attaches a bounded PDF artifact when present", async () => {
    const pdfBase64 = Buffer.from("%PDF-1.4 fake ticket bytes").toString("base64");
    const raw = multipartMessage(
      { From: "tickets@amtrak.com", Subject: "Your train booking confirmation" },
      "Train 171. Booking reference: XYZ987. Coach 3 Seat 12.",
      { filename: "ticket.pdf", mimeType: "application/pdf", base64: pdfBase64 },
    );

    const ticket = await parseForwardedTicket(raw, "message-key-4");
    expect(ticket?.artifact).toMatchObject({ filename: "ticket.pdf", mimeType: "application/pdf" });
    expect(ticket?.artifact?.data).toBe(pdfBase64);
  });

  it("drops an oversized attachment but still imports the ticket fields", async () => {
    const hugeBase64 = Buffer.from("A".repeat(2_000_000)).toString("base64");
    const raw = multipartMessage(
      { From: "tickets@amtrak.com", Subject: "Your train booking confirmation" },
      "Train 171. Booking reference: XYZ987. Coach 3 Seat 12.",
      { filename: "ticket.pdf", mimeType: "application/pdf", base64: hugeBase64 },
    );

    const ticket = await parseForwardedTicket(raw, "message-key-5");
    expect(ticket).not.toBeNull();
    expect(ticket?.trainNumber).toBe("171");
    expect(ticket?.artifact).toBeNull();
  });

  it("uses the parsed RFC822 Date header for receivedAt when it is valid", async () => {
    const raw = rawMessage(
      {
        From: "Trainline <tickets@trainline.com>",
        Subject: "Your train ticket to Paris",
        Date: "Tue, 03 Mar 2026 10:15:00 +0000",
      },
      "Train 9032. Booking reference: ABC123. Coach 7 Seat 42.",
    );

    const ticket = await parseForwardedTicket(raw, "message-key-date-valid");
    expect(ticket?.receivedAt).toBe("2026-03-03T10:15:00.000Z");
  });

  it("falls back to the current time when the Date header is missing or unparseable", async () => {
    const before = Date.now();
    const raw = rawMessage(
      {
        From: "Trainline <tickets@trainline.com>",
        Subject: "Your train ticket to Paris",
        Date: "not a real date",
      },
      "Train 9032. Booking reference: ABC123. Coach 7 Seat 42.",
    );

    const ticket = await parseForwardedTicket(raw, "message-key-date-invalid");
    const after = Date.now();
    expect(ticket).not.toBeNull();
    const receivedAtMillis = Date.parse(ticket?.receivedAt ?? "");
    expect(receivedAtMillis).toBeGreaterThanOrEqual(before);
    expect(receivedAtMillis).toBeLessThanOrEqual(after);
  });

  it("ignores unsupported attachment types", async () => {
    const raw = multipartMessage(
      { From: "tickets@amtrak.com", Subject: "Your train booking confirmation" },
      "Train 171. Booking reference: XYZ987. Coach 3 Seat 12.",
      { filename: "malware.exe", mimeType: "application/x-msdownload", base64: Buffer.from("binary").toString("base64") },
    );

    const ticket = await parseForwardedTicket(raw, "message-key-6");
    expect(ticket).not.toBeNull();
    expect(ticket?.artifact).toBeNull();
  });

  const logo = { filename: "trainline-logo.png", mimeType: "image/png", base64: "iVBORw0KGgo=" };
  const pdfTicket = { filename: "ticket.pdf", mimeType: "application/pdf", base64: "JVBERi0xLjQK" };

  it("does not treat a logo image as ticket evidence", async () => {
    const raw = multipartMessage(
      { From: "Trainline <offers@trainline.com>", Subject: "Autumn city breaks by rail" },
      "Passenger favourites this autumn: discover city breaks by rail across Europe.",
      logo,
    );
    expect(await parseForwardedTicket(raw, "message-key-logo")).toBeNull();
  });

  it("stores the PDF ticket rather than a logo that comes first", async () => {
    const raw = multipartMessage(
      { From: "Trainline <tickets@trainline.com>", Subject: "Your train ticket to Paris" },
      "London St Pancras to Paris Gare du Nord. Train 9032. Booking reference: ABC123.",
      [logo, pdfTicket],
    );
    const ticket = await parseForwardedTicket(raw, "message-key-logo-pdf");
    expect(ticket?.artifact).toMatchObject({ filename: "ticket.pdf", mimeType: "application/pdf" });
  });

  it("keeps an unnamed screenshot when the email itself proves the ticket", async () => {
    const raw = multipartMessage(
      { From: "Trainline <tickets@trainline.com>", Subject: "Your train ticket to Paris" },
      "London St Pancras to Paris Gare du Nord. Train 9032. Booking reference: ABC123.",
      { filename: "IMG_1234.jpg", mimeType: "image/jpeg", base64: "/9j/4AAQ" },
    );
    const ticket = await parseForwardedTicket(raw, "message-key-screenshot");
    expect(ticket?.artifact).toMatchObject({ filename: "IMG_1234.jpg", mimeType: "image/jpeg" });
  });
});
