/**
 * Boltpay — OG Preview Worker
 *
 * Domain-agnostic: the preview URL is rebuilt from the incoming request,
 * so one deployment serves every domain you attach it to.
 *
 * Per-model preview images: looks for assets/og/<slug>.png in the GitHub
 * repo with a HEAD request. If that file exists, it's used; otherwise it
 * falls back to og-default.png. The HEAD result is cached in the Worker's
 * Cache API so repeat crawls of the same slug don't re-check.
 */

const SUPABASE_URL = "https://ohwzmxwsphsfzudmlins.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9od3pteHdzcGhzZnp1ZG1saW5zIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODYwMzE0MTksImV4cCI6MjEwMTYwNzQxOX0.frTl7qnDx7SK2IBMQxFCkKGe5u4XAQweRxPhQ-2r8rU";
const SITE_NAME = "Boltpay";

// GitHub raw base — domain-independent, so previews never break when you
// add, remove, or rename a domain.
const OG_BASE =
  "https://raw.githubusercontent.com/parvezmosharafvu/boltpay/main/public/assets/og";
const OG_DEFAULT = `${OG_BASE}/og-default.png`;

const RESERVED = new Set([
  "", "login", "register", "dashboard", "admin", "index", "404", "config",
  "favicon", "theme", "assets", "u", "invoice-boltpay-v2",
  "dashboard-theme1-voltmeter", "dashboard-theme2-ledger",
  "dashboard-theme3-aurora", "dashboard-theme4-calm",
]);

const CRAWLER_PATTERNS = [
  "whatsapp", "facebookexternalhit", "telegrambot", "twitterbot",
  "linkedinbot", "discordbot", "slackbot", "skypeuripreview", "viber",
];

function isCrawler(userAgent) {
  if (!userAgent) return false;
  const ua = userAgent.toLowerCase();
  return CRAWLER_PATTERNS.some((p) => ua.includes(p));
}

function escapeHtml(str) {
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

async function fetchLinkPreviewData(slug) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/get_link_preview`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "apikey": SUPABASE_ANON_KEY,
      "Authorization": `Bearer ${SUPABASE_ANON_KEY}`,
    },
    body: JSON.stringify({ p_slug: slug }),
  });
  if (!res.ok) return null;
  const rows = await res.json();
  return Array.isArray(rows) ? rows[0] : rows;
}

/**
 * Returns the per-slug image if it exists in the repo, else the default.
 * Result is cached for an hour so a shared link doesn't trigger a HEAD
 * request on every single crawl.
 */
async function resolveOgImage(slug) {
  const candidate = `${OG_BASE}/${encodeURIComponent(slug)}.png`;
  const cacheKey = new Request(`https://og-check.internal/${slug}`);
  const cache = caches.default;

  try {
    const cached = await cache.match(cacheKey);
    if (cached) {
      const found = await cached.text();
      return found === "1" ? candidate : OG_DEFAULT;
    }

    const head = await fetch(candidate, { method: "HEAD" });
    const exists = head.ok;

    await cache.put(
      cacheKey,
      new Response(exists ? "1" : "0", {
        headers: { "Cache-Control": "max-age=3600" },
      })
    );

    return exists ? candidate : OG_DEFAULT;
  } catch (e) {
    console.error("OG image check failed:", e);
    return OG_DEFAULT;
  }
}

function renderOgHtml(origin, slug, data, ogImage) {
  const title = data?.display_name
    ? `Pay ${escapeHtml(data.display_name)} — ${SITE_NAME}`
    : `${SITE_NAME} — Lightning payment`;
  const description = `Send a secure Lightning payment via ${SITE_NAME}. Fast, low-fee, no account required to pay.`;
  const url = `${origin}/${encodeURIComponent(slug)}`;

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>${title}</title>
<meta property="og:site_name" content="${SITE_NAME}">
<meta property="og:title" content="${title}">
<meta property="og:description" content="${description}">
<meta property="og:image" content="${ogImage}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:url" content="${url}">
<meta property="og:type" content="website">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${title}">
<meta name="twitter:description" content="${description}">
<meta name="twitter:image" content="${ogImage}">
<meta http-equiv="refresh" content="0; url=${url}">
</head>
<body>
<p>Redirecting to <a href="${url}">${url}</a>…</p>
</body>
</html>`;
}

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/^\/|\/$/g, "");

    const looksLikeSlug =
      path.length > 0 && !path.includes("/") && !path.includes(".");
    if (!looksLikeSlug || RESERVED.has(path)) {
      return fetch(request);
    }

    if (!isCrawler(request.headers.get("User-Agent") || "")) {
      return fetch(request);
    }

    const data = await fetchLinkPreviewData(path);
    if (!data || data.is_active === false) {
      return fetch(request);
    }

    const ogImage = await resolveOgImage(path);

    return new Response(renderOgHtml(url.origin, path, data, ogImage), {
      headers: { "Content-Type": "text/html; charset=UTF-8" },
    });
  },
};
