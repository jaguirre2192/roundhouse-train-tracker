import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import {
  authConnectedPage,
  gmailConnectedPage,
  sharedTripPage,
} from "../src/cloudflare/public-pages.js";

const canonicalPages = [
  ["/", "https://gettraintracker.com/"],
  ["/privacy", "https://gettraintracker.com/privacy"],
  ["/terms", "https://gettraintracker.com/terms"],
  ["/support", "https://gettraintracker.com/support"],
] as const;

describe("public website canonicalization", () => {
  it("serves one self-referential canonical on every public page", async () => {
    for (const [path, canonical] of canonicalPages) {
      const response = await SELF.fetch(`https://gettraintracker.com${path}`);
      const html = await response.text();

      expect(response.status).toBe(200);
      expect(html.match(/rel="canonical"/gu)).toHaveLength(1);
      expect(html).toContain(`<link rel="canonical" href="${canonical}">`);
      expect(html).not.toContain("noindex");
    }
  });

  it("redirects protocol, host, and public-page slash variants in one hop", async () => {
    const cases = [
      ["http://gettraintracker.com/", "https://gettraintracker.com/"],
      ["http://www.gettraintracker.com/privacy", "https://gettraintracker.com/privacy"],
      ["https://www.gettraintracker.com/terms?source=test", "https://gettraintracker.com/terms?source=test"],
      ["https://gettraintracker.com/support/", "https://gettraintracker.com/support"],
      ["http://www.gettraintracker.com/privacy/", "https://gettraintracker.com/privacy"],
    ] as const;

    for (const [source, target] of cases) {
      const response = await SELF.fetch(source, { redirect: "manual" });

      expect(response.status).toBe(308);
      expect(response.headers.get("location")).toBe(target);
    }
  });

  it("does not redirect the API custom domain", async () => {
    const response = await SELF.fetch("https://api.gettraintracker.com/health", { redirect: "manual" });

    expect(response.status).toBe(200);
    expect(response.headers.get("location")).toBeNull();
  });

  it("publishes only the four canonical public URLs in the sitemap", async () => {
    const response = await SELF.fetch("https://gettraintracker.com/sitemap.xml");
    const xml = await response.text();

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toContain("application/xml");
    expect(xml.match(/<loc>/gu)).toHaveLength(4);
    for (const [, canonical] of canonicalPages) expect(xml).toContain(`<loc>${canonical}</loc>`);
    expect(xml).not.toContain("www.gettraintracker.com");
    expect(xml).not.toContain("http://gettraintracker.com");
  });

  it("advertises the canonical sitemap in robots.txt", async () => {
    const response = await SELF.fetch("https://gettraintracker.com/robots.txt");
    const robots = await response.text();

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toContain("text/plain");
    expect(robots).toContain("User-agent: *\nAllow: /");
    expect(robots).toContain("Sitemap: https://gettraintracker.com/sitemap.xml");
  });

  it("keeps signed share and authentication handoff pages out of search", async () => {
    const responses = [
      sharedTripPage("train-1", "2026-09-10", "signed-token"),
      gmailConnectedPage("one-time-code", "transaction"),
      authConnectedPage("one-time-code", "transaction"),
    ];

    for (const response of responses) {
      const html = await response.text();
      expect(html).toContain('<meta name="robots" content="noindex, nofollow">');
      expect(html).not.toContain('rel="canonical"');
    }
  });
});

describe("public product and policy pages", () => {
  it("serves public product, privacy, terms, and support pages", async () => {
    for (const path of ["/", "/privacy", "/terms", "/support"]) {
      const response = await SELF.fetch(`https://example.test${path}`);
      expect(response.status).toBe(200);
      expect(response.headers.get("content-type")).toContain("text/html");
      expect(await response.text()).toContain("Train Tracker");
    }
  });

  it("discloses ticket processing, connected accounts, retention, and data protections", async () => {
    const response = await SELF.fetch("https://example.test/privacy");
    const policy = await response.text();

    expect(policy).toContain("Updated November 18, 2026");
    expect(policy).toContain("without sending a purchase receipt or transaction identifier to the Roundhouse service");
    expect(policy).toContain("open, download or delete tickets you already received");
    expect(policy).toContain("You can change or turn off your address at any time");
    expect(policy).toContain("Original local ticket files and Calendar notes are not uploaded");
    expect(policy).toContain("including text recognition and barcode extraction");
    expect(policy).toContain("automatically uses its departure and arrival stations and departure time to find matching trains");
    expect(policy).toContain("Nothing is tracked until you confirm the journey");
    expect(policy).toContain("your email address and name when provided");
    expect(policy).toContain("retains the message subject, sender, receipt date");
    expect(policy).toContain("one PDF or image ticket attachment within the service's size limits");

    expect(policy).toContain("Data protection and security");
    expect(policy).toContain("HTTPS/TLS");
    expect(policy).toContain("encrypts its storage at rest");
    expect(policy).toContain("random alias nonce and a one-way token hash");
    expect(policy).toContain("Account ticket requests require an authenticated session");
    expect(policy).toContain("device notification requests use separate installation credentials");
    expect(policy).toContain("turn off forwarding to invalidate the alias while keeping previously imported tickets available");

    expect(policy).toContain("no longer offers Gmail import and no longer reads any mailbox");
    expect(policy).toContain("revoked every previously granted Gmail authorization with Google");
    expect(policy).toContain("rail-ticket records imported from Gmail");
    expect(policy).not.toContain("If you previously authorized read-only Gmail access and that connection remains active");

    expect(policy).toContain("New per-request invocation logging is disabled");
    expect(policy).toContain("infrastructure logs are configured to redact query strings");
    expect(policy).toContain("Historical infrastructure logs may still contain request URLs and query parameters");
    expect(policy).toContain("forwarding recipient addresses");
    expect(policy).toContain("remain until the platform's retention period expires");
    expect(policy).toContain("does not immediately erase historical infrastructure logs");
    expect(policy).not.toContain("Forwarded message contents, passenger data, booking references, and forwarding addresses are never included in operational logs");

    expect(policy).toContain("Turning off forwarding invalidates your address but leaves previously imported tickets available");
    expect(policy).toContain("When account deletion completes");
    expect(policy).toContain("connected Gmail records, and account-scoped imported tickets and attachments from live storage");
    expect(policy).toContain("Account deletion leaves locally saved journeys, trips, and tickets on your device");
    expect(policy).toContain("These device records are separate from your account and are not automatically deleted by account deletion");

  });

  it("describes optional tips and attributes the public routing sources", async () => {
    const terms = await (await SELF.fetch("https://example.test/terms")).text();
    expect(terms).toContain("Every feature is free. Optional tips help cover hosting.");
    const product = await (await SELF.fetch("https://example.test/")).text();
    expect(product).toContain("https://transitous.org/sources/");
    expect(product).toContain("https://www.openstreetmap.org/copyright");
    expect(product).toContain("https://github.com/jaguirre2192/roundhouse-train-tracker");
    expect(product).not.toContain("Nothing is scanned or read from your mailbox");
    expect(product).not.toContain("previously connected Gmail account");
  });

  it("serves the universal-link association for shared trips", async () => {
    const response = await SELF.fetch("https://example.test/.well-known/apple-app-site-association");
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      applinks: {
        details: [{
          appIDs: expect.arrayContaining(["EXAMPLETEAM.com.jorgeaguirre.TrainTracker"]),
          components: expect.arrayContaining([
            { "/": "/gmail-connected", comment: expect.any(String) },
            { "/": "/auth-connected", comment: expect.any(String) },
          ]),
        }],
      },
    });
  });
});
