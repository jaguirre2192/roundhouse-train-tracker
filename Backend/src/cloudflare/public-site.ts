export const publicSiteOrigin = "https://gettraintracker.com";

export const publicPagePaths = ["/", "/privacy", "/terms", "/support"] as const;
export type PublicPagePath = typeof publicPagePaths[number];

const publicSiteHosts = new Set([
  "gettraintracker.com",
  "www.gettraintracker.com",
]);

const publicTrailingSlashPaths = new Map([
  ["/privacy/", "/privacy"],
  ["/terms/", "/terms"],
  ["/support/", "/support"],
]);

export function publicSiteURL(path: PublicPagePath): string {
  return new URL(path, publicSiteOrigin).toString();
}

export function canonicalPublicSiteRedirect(url: URL): Response | null {
  if (!publicSiteHosts.has(url.hostname)) return null;

  const pathname = publicTrailingSlashPaths.get(url.pathname) ?? url.pathname;
  const isCanonical = url.protocol === "https:"
    && url.hostname === "gettraintracker.com"
    && pathname === url.pathname;
  if (isCanonical) return null;

  const target = new URL(`${pathname}${url.search}`, publicSiteOrigin);
  return new Response(null, {
    status: 308,
    headers: {
      "cache-control": "public, max-age=86400",
      location: target.toString(),
    },
  });
}

export function sitemapResponse(): Response {
  const urls = publicPagePaths
    .map((path) => `  <url><loc>${publicSiteURL(path)}</loc></url>`)
    .join("\n");

  return new Response(`<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${urls}
</urlset>
`, {
    headers: {
      "cache-control": "public, max-age=3600",
      "content-type": "application/xml; charset=utf-8",
      "x-content-type-options": "nosniff",
    },
  });
}

export function robotsResponse(): Response {
  return new Response(`User-agent: *
Allow: /

Sitemap: ${publicSiteOrigin}/sitemap.xml
`, {
    headers: {
      "cache-control": "public, max-age=3600",
      "content-type": "text/plain; charset=utf-8",
      "x-content-type-options": "nosniff",
    },
  });
}
