import { describe, expect, it } from "vitest";
import { isRejectedGmailSubject, parseGmailTicket } from "../src/gmail/gmail-parser.js";

function encoded(value: string): string {
  return Buffer.from(value).toString("base64url");
}

describe("Gmail train ticket parser", () => {
  it("identifies previously stored non-ticket subjects for reconciliation", () => {
    expect(isRejectedGmailSubject("Your Classique membership has been renewed")).toBe(true);
    expect(isRejectedGmailSubject("Confirmation code")).toBe(true);
    expect(isRejectedGmailSubject("Updates to our Terms & Conditions")).toBe(true);
    expect(isRejectedGmailSubject("It's almost time for your trip to Madrid-Puerta de Atocha-Almudena Grandes")).toBe(true);
    expect(isRejectedGmailSubject("Última hora sobre tu viaje")).toBe(true);
    expect(isRejectedGmailSubject("Your train booking confirmation code")).toBe(false);
  });

  it("extracts a rail confirmation and retains only an attachment reference", () => {
    const value = parseGmailTicket({
      id: "message-123",
      internalDate: String(Date.parse("2026-07-21T12:00:00Z")),
      payload: {
        headers: [
          { name: "Subject", value: "Your train ticket to Paris" },
          { name: "From", value: "Trainline <tickets@trainline.com>" },
        ],
        parts: [
          {
            partId: "0",
            mimeType: "text/plain",
            body: { data: encoded("London St Pancras to Paris Gare du Nord. Train 9032. Booking reference: ABC123. Coach 7 Seat 42.") },
          },
          {
            partId: "1",
            mimeType: "application/pdf",
            filename: "ticket.pdf",
            body: { attachmentId: "attachment-secret-id", size: 9000 },
          },
        ],
      },
    });

    expect(value).toMatchObject({
      operatorName: "Trainline",
      trainNumber: "9032",
      bookingReference: "ABC123",
      coach: "7",
      seat: "42",
      artifact: {
        attachmentId: "attachment-secret-id",
        filename: "ticket.pdf",
      },
    });
    expect(JSON.stringify(value)).not.toContain("London St Pancras to Paris Gare du Nord. Train");
  });

  it("ignores unrelated messages", () => {
    expect(parseGmailTicket({
      id: "newsletter",
      snippet: "Weekly recipes and garden ideas",
      payload: { headers: [{ name: "Subject", value: "Your Sunday newsletter" }] },
    })).toBeNull();
  });

  it.each([
    {
      id: "data-portal-notification",
      subject: "National Rail Data Portal: Notification",
      sender: "National Rail Data Portal <noreply@publicdata.example>",
      body: "Your National Rail Data Portal account requires attention. This is an API account notification, not a passenger booking.",
    },
    {
      id: "train-as-a-verb",
      subject: "This world champion won't train without this routine",
      sender: "Daily Fitness <news@fitness.example>",
      body: "During training, he follows a simple plan every morning.",
    },
    {
      id: "rail-editorial",
      subject: "Five Spring Train Journeys Worth Taking",
      sender: "Travel Magazine <newsletter@travel.example>",
      body: "A collection of scenic railway stories and station guides for your next holiday.",
    },
    {
      id: "event-ticket",
      subject: "'From Successful to Scalable' — Get Your Tickets",
      sender: "Business Events <events@conference.example>",
      body: "Reserve your event ticket and train your team with successful founders.",
    },
    {
      id: "airline-trip",
      subject: "Envoy Air Inc",
      sender: "Envoy Air <updates@envoyair.example>",
      body: "Use these tips to prepare for your trip. Airport ground transportation may include a train.",
    },
    {
      id: "operator-marketing",
      subject: "Five Spring Train Journeys Worth the Trip",
      sender: "Trainline <offers@trainline.com>",
      body: "Explore inspiring destinations and save on your next getaway.",
    },
    {
      id: "eurostar-membership-renewal",
      subject: "Your Classique membership has been renewed",
      sender: "Club Eurostar <loyalty@e.eurostar.com>",
      body: "For another new membership year, enjoy member benefits, tickets, Train + Hotel, and inspiration for your next journey.",
    },
    {
      id: "deutsche-bahn-account-confirmation",
      subject: "Confirmation code",
      sender: "Deutsche Bahn <noreply@bahn.de>",
      body: "Hello, Please confirm your email address to actively use your DB customer account. Your confirmation code: 706260.",
    },
    {
      id: "amtrak-terms-update",
      subject: "Updates to our Terms & Conditions",
      sender: "Amtrak Guest Rewards <amtrak@e-mail.amtrak.com>",
      body: "Updates to our Terms & Conditions. Our mailing address is Amtrak Guest Rewards, Washington, DC. Passenger Rail Investment and Improvement Act.",
    },
    {
      id: "omio-pretrip-reminder",
      subject: "It's almost time for your trip to Madrid-Puerta de Atocha-Almudena Grandes",
      sender: "Omio Booking Team <booking@news.omio.com>",
      body: "Fri, Aug 14, 2026\nValencia-Joaquín Sorolla – Madrid-Puerta de Atocha-Almudena Grandes\nReady for your journey? View all your booking details in the app.",
    },
    {
      id: "renfe-last-minute-reminder",
      subject: "Última hora sobre tu viaje",
      sender: "Renfe <clientes@clientes.renfe.es>",
      body: "Renfe AVE 05951. Information for your journey.",
    },
  ])("rejects the reported non-ticket candidate: $id", ({ id, subject, sender, body }) => {
    expect(parseGmailTicket({
      id,
      snippet: body,
      payload: {
        headers: [
          { name: "Subject", value: subject },
          { name: "From", value: sender },
        ],
        parts: [{ mimeType: "text/plain", body: { data: encoded(body) } }],
      },
    })).toBeNull();
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
  ])("rejects an operator non-ticket message even when it names a train: $id", ({ id, subject, sender, body }) => {
    expect(parseGmailTicket({
      id,
      snippet: body,
      payload: {
        headers: [
          { name: "Subject", value: subject },
          { name: "From", value: sender },
        ],
        parts: [{ mimeType: "text/plain", body: { data: encoded(body) } }],
      },
    })).toBeNull();
  });

  it("accepts a genuine no-PNR ticket with dated route and ownership evidence", () => {
    const ticket = parseGmailTicket({
      id: "amtrak-no-pnr-ticket",
      payload: {
        headers: [
          { name: "Subject", value: "Your Amtrak travel details" },
          { name: "From", value: "Amtrak <tickets@amtrak.com>" },
        ],
        parts: [{
          mimeType: "text/plain",
          body: { data: encoded([
            "Passenger: Alex Rivera",
            "Date: 14/09/2026",
            "From: New York Penn Station",
            "To: Washington Union Station",
            "Train 171",
            "Coach 4",
            "Seat 12A",
          ].join("\n")) },
        }],
      },
    });

    expect(ticket).toMatchObject({
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

  it("accepts a forwarded genuine rail confirmation from an unknown sender", () => {
    expect(parseGmailTicket({
      id: "forwarded-ticket",
      payload: {
        headers: [
          { name: "Subject", value: "Fwd: Train ticket booking – Amtrak" },
          { name: "From", value: "Jorge <jorge@example.com>" },
        ],
        parts: [{
          mimeType: "text/plain",
          body: { data: encoded("New York Penn Station to Washington Union Station. Train 171. Booking reference: RAIL42.") },
        }],
      },
    })).toMatchObject({
      trainNumber: "171",
      bookingReference: "RAIL42",
    });
  });

  it("does not reject a train booking merely because its subject mentions a confirmation code", () => {
    expect(parseGmailTicket({
      id: "booking-confirmation-code",
      payload: {
        headers: [
          { name: "Subject", value: "Your train booking confirmation code" },
          { name: "From", value: "Rail Tickets <tickets@example.com>" },
        ],
        parts: [{
          mimeType: "text/plain",
          body: { data: encoded("London Euston to Manchester Piccadilly. Train 220. Booking reference: RAIL220.") },
        }],
      },
    })).toMatchObject({
      trainNumber: "220",
      bookingReference: "RAIL220",
    });
  });

  it("extracts the sanitized verification ticket without bleeding across fields", () => {
    expect(parseGmailTicket({
      id: "verification-fixture",
      internalDate: String(Date.parse("2026-08-07T18:00:00Z")),
      payload: {
        headers: [
          { name: "Subject", value: "Train Tracker Review — Rail ticket confirmation" },
          { name: "From", value: "Jorge <jorge@example.com>" },
        ],
        parts: [{
          mimeType: "text/plain",
          body: { data: encoded([
            "Sanitized verification fixture — no real traveler or booking data.",
            "London St Pancras to Paris Gare du Nord",
            "Train 9032",
            "Booking reference: TTDEMO26",
            "Passenger: Alex Rivera",
            "Coach 7",
            "Seat 42A",
          ].join(" ")) },
        }],
      },
    })).toMatchObject({
      originName: "London St Pancras",
      destinationName: "Paris Gare du Nord",
      trainNumber: "9032",
      bookingReference: "TTDEMO26",
      passengerName: "Alex Rivera",
      coach: "7",
      seat: "42A",
    });
  });

  it("recognizes a Renfe QR reminder with Spanish route labels", () => {
    expect(parseGmailTicket({
      id: "renfe-qr-reminder",
      internalDate: String(Date.parse("2026-08-13T16:00:00Z")),
      payload: {
        headers: [
          { name: "Subject", value: "Jorge, tu viaje de mañana a Madrid-Puerta de Atocha-Almudena Grandes: accede al tren con el QR" },
          { name: "From", value: "Renfe <renfe@clientes.renfe.es>" },
        ],
        parts: [{
          mimeType: "text/html",
          body: { data: encoded("<p>Fecha: 14/08/2026</p><p>Origen: València-Joaquín Sorolla 15:09h</p><p>Destino: Madrid-Puerta de Atocha-Almudena Grandes 17:17h</p><p>Tren: AVE 05951 Coche: 002 Plaza: 07C</p><p>Accede al tren con tu QR.</p>") },
        }],
      },
    })).toMatchObject({
      operatorName: "Renfe",
      originName: "València-Joaquín Sorolla",
      destinationName: "Madrid-Puerta de Atocha-Almudena Grandes",
      departureTime: "2026-08-14T15:09:00+02:00",
      trainNumber: "AVE 05951",
      coach: "002",
      seat: "07C",
    });
  });

  it("keeps an unknown operator's local departure time date-only", () => {
    expect(parseGmailTicket({
      id: "unknown-local-time",
      payload: {
        headers: [
          { name: "Subject", value: "Your train ticket" },
          { name: "From", value: "Rail Tickets <tickets@example.com>" },
        ],
        parts: [{
          mimeType: "text/plain",
          body: { data: encoded([
            "Date: 14/08/2026",
            "From: London Euston 15:09",
            "To: Manchester Piccadilly",
            "Booking reference: RAIL220",
          ].join("\n")) },
        }],
      },
    })).toMatchObject({ departureTime: "2026-08-14" });
  });

  it("extracts the route after prose that introduces an explicit from/to pair", () => {
    expect(parseGmailTicket({
      id: "prose-route-ticket",
      payload: {
        headers: [
          { name: "Subject", value: "Your rail booking confirmation" },
          { name: "From", value: "Rail Operator <tickets@example.com>" },
        ],
        parts: [{
          mimeType: "text/plain",
          body: { data: encoded("Your journey is from Brussels Midi to Amsterdam Centraal. Train 9327. Booking reference: DEMO9327.") },
        }],
      },
    })).toMatchObject({
      originName: "Brussels Midi",
      destinationName: "Amsterdam Centraal",
    });
  });
});
