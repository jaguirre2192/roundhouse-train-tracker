import { publicSiteURL, type PublicPagePath } from "./public-site.js";

const sharedStyles = `
  :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  body { margin: 0; background: #f4f0e7; color: #10212b; }
  main { max-width: 720px; margin: 0 auto; padding: 72px 24px 96px; }
  h1 { font-size: clamp(2.4rem, 8vw, 4.8rem); letter-spacing: -0.055em; line-height: 0.95; margin: 0 0 24px; }
  h2 { margin-top: 36px; font-size: 1.25rem; }
  p, li { font-size: 1.04rem; line-height: 1.65; }
  a { color: #086f83; }
  .eyebrow { font-size: 0.78rem; font-weight: 700; letter-spacing: 0.13em; text-transform: uppercase; }
  .lede { font-size: 1.3rem; max-width: 600px; }
  nav { display: flex; gap: 20px; margin-top: 42px; }
  @media (prefers-color-scheme: dark) {
    body { background: #10212b; color: #f4f0e7; }
    a { color: #66d5e6; }
  }
`;

interface PageOptions {
  cacheControl?: string;
  canonicalPath?: PublicPagePath;
  robots?: "noindex, nofollow";
}

function page(title: string, body: string, options: PageOptions = {}): Response {
  const canonical = options.canonicalPath === undefined
    ? ""
    : `\n  <link rel="canonical" href="${escaped(publicSiteURL(options.canonicalPath))}">`;
  const robots = options.robots === undefined
    ? ""
    : `\n  <meta name="robots" content="${options.robots}">`;

  return new Response(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${title}</title>${canonical}${robots}
  <style>${sharedStyles}</style>
</head>
<body><main>${body}</main></body>
</html>`, {
    headers: {
      "cache-control": options.cacheControl ?? "public, max-age=3600",
      "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'",
      "content-type": "text/html; charset=utf-8",
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
    },
  });
}

function escaped(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

export function sharedTripPage(tripId: string, serviceDate: string, token: string): Response {
  return page("Shared train — Global Train Tracker", `
    <p class="eyebrow">Shared with Global Train Tracker</p>
    <h1>A train is ready to add.</h1>
    <p class="lede">Service ${escaped(serviceDate)}</p>
    <p>Train reference <strong>${escaped(tripId)}</strong>. Ticket documents, passenger names, booking references, and barcodes are never included in shared trip links.</p>
    <p><a href="traintracker://share/${encodeURIComponent(token)}">Open in Global Train Tracker</a></p>
    <nav><a href="/privacy">Privacy</a><a href="/support">Support</a></nav>
  `, { robots: "noindex, nofollow" });
}

export function gmailConnectedPage(code: string, transactionId: string): Response {
  return page("Gmail connected — Global Train Tracker", `
    <p class="eyebrow">Global Train Tracker</p>
    <h1>Your inbox is connected.</h1>
    <p class="lede">Global Train Tracker can now organize matching rail confirmations even while your device is offline.</p>
    <p><a href="traintracker://gmail-connected?code=${encodeURIComponent(code)}&transaction=${encodeURIComponent(transactionId)}">Open Global Train Tracker</a></p>
    <p>This one-time handoff expires in five minutes. You can close this page after the app opens.</p>
    <nav><a href="/privacy">Privacy</a><a href="/terms">Terms</a><a href="/support">Support</a></nav>
  `, { cacheControl: "private, no-store", robots: "noindex, nofollow" });
}

export function authConnectedPage(code: string, transactionId: string): Response {
  return page("Signed in — Global Train Tracker", `
    <p class="eyebrow">Global Train Tracker</p>
    <h1>You’re signed in.</h1>
    <p class="lede">Return to Global Train Tracker to continue with your trips and connected inboxes.</p>
    <p><a href="traintracker://auth-connected?code=${encodeURIComponent(code)}&transaction=${encodeURIComponent(transactionId)}">Open Global Train Tracker</a></p>
    <p>This one-time handoff expires in five minutes and works only in the app that started it.</p>
    <nav><a href="/privacy">Privacy</a><a href="/terms">Terms</a><a href="/support">Support</a></nav>
  `, { cacheControl: "private, no-store", robots: "noindex, nofollow" });
}

export function appleAppSiteAssociation(): Response {
  return Response.json({
    applinks: {
      details: [{
        appIDs: [
          "EXAMPLETEAM.com.jorgeaguirre.TrainTracker",
          "EXAMPLETEAM.com.jorgeaguirre.TrainTracker.mac",
        ],
        components: [
          { "/": "/s/*", comment: "Train Tracker shared-trip links" },
          { "/": "/gmail-connected", comment: "Train Tracker Gmail OAuth handoff" },
          { "/": "/auth-connected", comment: "Train Tracker account sign-in handoff" },
        ],
      }],
    },
  }, {
    headers: {
      "cache-control": "public, max-age=3600",
      "content-type": "application/json",
    },
  });
}

export function productPage(): Response {
  return page("Global Train Tracker — Live Rail", `
    <p class="eyebrow">Global Train Tracker</p>
    <h1>Know what changed before you board.</h1>
    <p class="lede">A free, ad-free train companion for live departures, per-stop delays, platforms, alerts, and vehicle positions when providers publish them.</p>
    <p>Global Train Tracker supports Amtrak in the United States, mainline passenger rail in 39 verified European countries, verified intercity services in Canada, Australia, India, Morocco, Malaysia, and Thailand, official schedule-only Chepe Express coverage in Mexico, schedule-led TRA and THSR rail in Taiwan, and Korail mainline schedules in South Korea. Taiwan uses server-cached TDX GTFS schedules and does not provide realtime estimates, cancellations or platforms. Metro, subway, tram, and light-rail services are excluded. Nationwide Japanese Shinkansen, China, and several provider gaps are planned or awaiting licensed credentials. Coverage and realtime capabilities vary by operator and country.</p>
    <p>Journey planning uses <a href="https://transitous.org/sources/">Transitous and its data providers</a>, with map data from <a href="https://www.openstreetmap.org/copyright">© OpenStreetMap contributors</a>.</p>
    <p><a href="https://github.com/jaguirre2192/roundhouse-train-tracker">Roundhouse source code on GitHub</a>.</p>
    <p>Taiwan timetable attribution: Ministry of Transportation and Communications Transportation Data Circulation Service Platform. Data is provided under the <a href="https://data.gov.tw/license">Open Government Data License 1.0</a> and TDX terms through the <a href="https://github.com/jcanizalez/tdx-gtfs-mirror">TDX GTFS mirror</a>.</p>
    <p>Korail timetable and GTFS-RT attribution: To Mikołaj Kuranowski, <a href="https://mkuran.pl/gtfs/">mkuran.pl</a>, <a href="https://creativecommons.org/licenses/by/4.0/">CC BY 4.0</a>. Data is filtered and normalized for this service. Whole-trip delay metadata is separate from scheduled stop times; no stop forecasts, platforms or cancellations are inferred. Vehicle points without an observation timestamp are withheld.</p>
    <h2>Your tickets, already organized</h2>
    <p>Import a photo, PDF, or ticket text on your device, or forward a rail confirmation to your private Global Train Tracker address. Local originals stay on your device; complete ticket details use the stations and departure time to find matching trains automatically. Forwarded emails are processed by the service, which keeps ticket fields and a size-limited ticket attachment for your account. In Settings, you can change or turn off your forwarding address at any time. See the privacy policy for details.</p>
    <h2>Share the train, not the ticket</h2>
    <p>Signed trip links let another Global Train Tracker user add the same service without exposing passenger names, booking references, ticket documents, or barcodes.</p>
    <nav><a href="/privacy">Privacy</a><a href="/terms">Terms</a><a href="/support">Support</a></nav>
  `, { canonicalPath: "/" });
}

export function privacyPage(): Response {
  return page("Privacy Policy — Global Train Tracker", `
    <p class="eyebrow">Updated November 18, 2026</p>
    <h1>Privacy Policy</h1>
    <p>Global Train Tracker has no advertising, behavioral analytics, personal-data sales, or cross-app tracking. The data described below is used to provide requested features, protect the service, and maintain its reliability.</p>
    <h2>Tickets, Calendar, and other data on your device</h2>
    <p>Photos, screenshots, PDFs, pasted ticket text, email files, and Share sheet imports are read on your device, including text recognition and barcode extraction. Original files, extracted details, and unfinished reviews are saved locally so you can use them offline. Calendar import reads event titles, notes, locations, and times on your device after you grant permission and choose to use the feature. Original local ticket files and Calendar notes are not uploaded to Global Train Tracker by these imports.</p>
    <p>A complete imported journey automatically uses its departure and arrival stations and departure time to find matching trains. Incomplete imports ask you to add or check the missing details before searching. Manual searches also send the station search text or selected route and time to the service and its rail-data providers. Nothing is tracked until you confirm the journey. Enabling alerts or a Live Activity then sends the selected train details described below.</p>
    <p>Saved journeys and trips remain on your device. If you allow location access, the app uses your location to show you on the map; it does not send your device GPS location to Global Train Tracker's service.</p>
    <h2>Meet My Train</h2>
    <p>If you create an arrival board, the service encrypts the selected train and stop, its timetable and your optional meeting note. Anyone with the private link can read that stop’s arrival updates and note in a browser. Your ticket, booking reference and device location stay private. A reported arrival or passage closes the board one hour after the time the operator reports. If no arrival is reported, it expires twelve hours after the later scheduled or estimated arrival available when you create it. Expired boards are removed during service maintenance.</p>
    <h2>Accounts and sign-in</h2>
    <p>If you sign in with Apple or Google, Global Train Tracker retains an account identifier, the sign-in provider's identifier, your email address and name when provided, and session records. These support sign-in and account features such as ticket forwarding. Credentials needed to maintain authorized access are stored encrypted or as one-way hashes, as appropriate. Signing in with Google does not itself authorize Gmail access; that requires separate read-only permission.</p>
    <p>If you leave an optional tip, Apple processes the payment. The app handles the purchase on your device without sending a purchase receipt or transaction identifier to the Roundhouse service.</p>
    <h2>Voluntary ticket forwarding</h2>
    <p>When you enable ticket forwarding, your signed-in account gets a private address under gettraintracker.com. You can change or turn off your address at any time. You can also open, download or delete tickets you already received. When you forward a rail confirmation to that address, Cloudflare Email Routing delivers it to the service for parsing. For accepted tickets, Global Train Tracker retains the message subject, sender, receipt date, and extracted details such as operator, route, service number, travel times, passenger name, seat, coach, and booking reference. It may also retain one PDF or image ticket attachment within the service's size limits. These records are linked to your account. The full raw email is processed to extract the ticket rather than kept as your ticket record. Messages that fail ticket, size, or sender-authentication checks are not imported as tickets.</p>
    <p>Forwarding-address recognition uses a random alias nonce and a one-way token hash. The address is derived for authenticated account requests using a service secret. You can rotate the address to invalidate the previous one, or turn off forwarding to invalidate the alias while keeping previously imported tickets available.</p>
    <h2>Discontinued Gmail import</h2>
    <p>Global Train Tracker no longer offers Gmail import and no longer reads any mailbox. In October 2026 the service revoked every previously granted Gmail authorization with Google and deleted the connected email addresses, encrypted authorization credentials, scan state, and rail-ticket records imported from Gmail. Your Global Train Tracker account, sign-in, and forwarding records are unaffected.</p>
    <h2>Data protection and security</h2>
    <p>Global Train Tracker uses HTTPS/TLS for data sent to its service. Account, forwarding, imported-ticket, notification, and Live Activity records are stored in private Cloudflare infrastructure, which encrypts its storage at rest. Service secrets are managed separately from the app and source code. Account ticket requests require an authenticated session; device notification requests use separate installation credentials. Locally saved original tickets and cached attachments use iOS file protection.</p>
    <h2>Notifications and Live Activities</h2>
    <p>If you enable notifications and track a trip, the app sends a random installation identifier, an Apple Push Notification service token, device platform, selected train identifier, service date, boarding and destination station identifiers, and notification preferences. Live Activities also send their activity identifiers and push tokens, selected-stop and time-zone information, and the activity state needed for updates. The service retains these records, delivery attempts, and delivery status or errors to monitor your selected trips and provide requested alerts and Live Activity updates. These records are associated with your installation and are managed separately from your sign-in account.</p>
    <h2>Search, operational records, and historical logs</h2>
    <p>The service temporarily caches public station and journey results to answer searches efficiently. Operational metrics record request timing, provider, cache use, and outcome without ticket contents or account identifiers. Delivery diagnostics, connection errors, and security or rate-limit records may be associated with an account or installation identifier. They are used for reliability, access protection, and requested feature delivery, rather than advertising or behavioral analytics.</p>
    <p>New per-request invocation logging is disabled, and infrastructure logs are configured to redact query strings. Historical infrastructure logs may still contain request URLs and query parameters, including station searches or sign-in parameters, and forwarding recipient addresses. Those records may remain until the platform's retention period expires. Changing logging settings or deleting an account does not immediately erase historical infrastructure logs.</p>
    <h2>Storage and deletion</h2>
    <p>You can delete locally saved tickets in the app. Turning off forwarding invalidates your address but leaves previously imported tickets available until you delete them individually or delete your account. When account deletion completes, the service removes your account profile, sign-in identities and sessions, forwarding alias, connected Gmail records, and account-scoped imported tickets and attachments from live storage. Cloudflare database recovery copies may retain earlier data for up to 30 days. Account deletion leaves locally saved journeys, trips, and tickets on your device; manage those separately in the app.</p>
    <p>Stopping tracking deactivates that trip's server alert subscription. It does not immediately erase the installation, inactive subscriptions, Live Activity records, or associated delivery diagnostics. These device records are separate from your account and are not automatically deleted by account deletion. You may request deletion of inactive device, notification, or import records using the contact below. Historical infrastructure logs remain subject to the platform retention described above.</p>
    <h2>Third-party services</h2>
    <p>The Global Train Tracker service retrieves rail information from Amtraker, Transitous, iRail, Renfe, Fintraffic Digitraffic, Entur, SNCF, Deutsche Bahn, NS, ÖBB, the Swiss Open Transport Data platform, Iarnród Éireann, Translink, National Rail Darwin, Trafiklab, mobiliteit.lu, Elron, KTMB, Chepe Express, the TDX GTFS mirror, mkuran.pl Korail feeds, and their underlying public-transport data sources. VIA Rail schedule and route-geometry information is licensed under the <a href="https://open.canada.ca/en/open-government-licence-canada">Open Government Licence – Canada 2.0</a>; source information is available from <a href="https://www.viarail.ca/en/developer-resources">VIA Rail Developer Resources</a>. Amtrak route lines come from the <a href="https://geodata.bts.gov/datasets/usdot::amtrak-routes/about">Amtrak Routes dataset</a> in the National Transportation Atlas Database, published by the U.S. Department of Transportation Bureau of Transportation Statistics with the Federal Railroad Administration and Amtrak. Transwa schedule data is available free of charge from <a href="https://www.transperth.wa.gov.au/About/Spatial-Data-Access">Transperth</a>; Mexican schedule-only coverage is based on the <a href="https://chepe.mx/tren/horarios/">official Chepe Express timetable</a>. If licensed and enabled, the service may also retrieve rail information from Ekispert for Japan and TDX for Taiwan. Version 1.7 and later request rail information through the Global Train Tracker service. Earlier app versions may contact Amtraker or Transitous directly when the service is unavailable. Cloudflare provides service storage, request processing, and email routing. Apple and Google process their respective sign-in flows; Google also processes any separately authorized Gmail access. Apple processes push and Live Activity tokens and provides map services.</p>
    <p>Older app versions that display city photographs use public station coordinates with Apple's geocoder and city or image-file queries with Wikipedia and Wikimedia Commons. Images are downloaded from Wikimedia, cached on your device, and credited in the app. These network requests do not include local ticket contents or booking references, but providers receive ordinary network metadata such as your IP address. Image lookups use a session without stored cookies or credentials.</p>
    <p>If you choose to open a ticket retailer, the app opens the retailer's general website in a browser. The current Omio handoff does not include your passenger details, booking reference, payment information, or selected itinerary in the link. The retailer handles its own browsing, booking, and payment data under its own privacy policy; Global Train Tracker does not collect your retailer payment details.</p>
    <h2>Sharing</h2>
    <p>A trip-share link contains a signed public train reference, service date, and optional boarding and destination station identifiers. It never includes forwarded message contents, ticket documents, passenger names, booking references, or barcodes. Anyone with the link can add the referenced train until the link expires. Global Train Tracker does not sell personal data or share it for advertising. Data is disclosed only to the infrastructure and rail-data providers needed to operate requested features, or when required by law.</p>
    <h2>Contact</h2>
    <p>Questions or deletion requests can be sent to <a href="mailto:support@example.invalid">support@example.invalid</a>.</p>
    <nav><a href="/">Global Train Tracker</a><a href="/terms">Terms</a><a href="/support">Support</a></nav>
  `, { canonicalPath: "/privacy" });
}

export function termsPage(): Response {
  return page("Terms of Use — Global Train Tracker", `
    <p class="eyebrow">Updated November 18, 2026</p>
    <h1>Terms of Use</h1>
    <p>Roundhouse is a free, open-source companion for personal rail travel. By using the hosted service, you agree to use it lawfully and follow the terms of its data providers.</p>
    <p>Every feature is free. Optional tips help cover hosting. Apple processes these one-time purchases. Roundhouse grants the same access to every rider.</p>
    <h2>Travel information</h2>
    <p>Schedules, platforms, delays, cancellations, positions, and predictions come from third-party rail data and may be late, incomplete, or incorrect. Global Train Tracker is not a rail operator, ticket seller, or transportation authority. Always follow station announcements and confirm time-critical information with the operator. You remain responsible for reaching and boarding the correct service and for carrying a valid ticket.</p>
    <p>Regional Czech rail positions are supplied by <a href="https://golemio.cz">Golemio</a> and <a href="https://pid.cz">ROPID / Prague Integrated Transport (PID)</a>. Latvian Vivi positions use the merged realtime feed published by <a href="https://pieturas.lv">Pieturas</a> (<a href="https://gsvalbe.id.lv/pieturas/avoti.html">sources and reuse information</a>), with original operator data from <a href="https://vivi.lv">Vivi</a>. Data is matched and filtered for service identity, freshness and plausibility by Global Train Tracker.</p>
    <h2>Ticket forwarding</h2>
    <p>Ticket forwarding is optional. You choose which messages to forward to your private Global Train Tracker address, and the service imports only messages it can identify with high confidence as your own rail tickets. While forwarding is active, you can rotate the address. You can turn it off at any time. Do not forward another person's ticket or mailbox contents without their permission, and do not use the forwarding address for anything other than your own rail confirmations.</p>
    <h2>Sharing</h2>
    <p>Anyone who receives an unexpired trip-share link can add its public train reference. Do not post links where you do not intend them to be used. Ticket documents, passenger names, booking references, and barcodes are not included in shared links.</p>
    <h2>Availability and acceptable use</h2>
    <p>The service is provided as available and may change or stop without notice. You may not probe, overload, automate abusive traffic against, reverse engineer access controls for, or use Global Train Tracker to violate provider terms or applicable law.</p>
    <h2>Contact</h2>
    <p>Questions can be sent to <a href="mailto:support@example.invalid">support@example.invalid</a>.</p>
    <nav><a href="/">Global Train Tracker</a><a href="/privacy">Privacy</a><a href="/support">Support</a></nav>
  `, { canonicalPath: "/terms" });
}

export function supportPage(): Response {
  return page("Support — Global Train Tracker", `
    <p class="eyebrow">Global Train Tracker</p>
    <h1>Support</h1>
    <p class="lede">Need help with a trip, notification, or data source?</p>
    <h2>Before contacting support</h2>
    <ul>
      <li>Pull down on My Trips to refresh the latest available rail data.</li>
      <li>Check notification permission in System Settings if alerts are missing.</li>
      <li>Remember that platforms and positions appear only when the operator publishes them.</li>
      <li>Confirm time-critical travel information with the train operator.</li>
      <li>If a forwarded ticket does not import, confirm the message contains a rail operator or train reference and was sent to your current forwarding address, then try forwarding it again.</li>
    </ul>
    <p>Email <a href="mailto:support@example.invalid">support@example.invalid</a> with the train number, service date, country, and a short description of the issue. Do not include ticket barcodes or payment details.</p>
    <nav><a href="/">Global Train Tracker</a><a href="/privacy">Privacy</a><a href="/terms">Terms</a></nav>
  `, { canonicalPath: "/support" });
}
