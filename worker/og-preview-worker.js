/**
 * Boltpay — OG Preview Worker
 *
 * Runs on every domain you attach it to. Nothing about the domain is
 * hardcoded: the OG url is rebuilt from the incoming request, so the
 * preview card always shows the domain the link was actually shared on.
 *
 * The only fixed URL is the fallback OG image, which is served from the
 * GitHub repo (raw.githubusercontent.com) so it never depends on which
 * domain is live.
 */

const SUPABASE_URL = "https://ohwzmxwsphsfzudmlins.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9od3pteHdzcGhzZnp1ZG1saW5zIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODYwMzE0MTksImV4cCI6MjEwMTYwNzQxOX0.frTl7qnDx7SK2IBMQxFCkKGe5u4XAQweRxPhQ-2r8rU";
const SITE_NAME = "Boltpay";

// Served from GitHub so it is domain-independent. Replace the branch/path
// if you move the file. Commit an image at public/assets/og-default.png.
const DEFAULT_OG_IMAGE =
  "https://raw.githubusercontent.com/parvezmosharafvu/boltpay/main/public/assets/og-default.png";

const RESERVED = new Set([
  "", "login", "register", "dashboard", "admin", "index", "404", "config",
  "favicon", "assets", "u", "invoice-boltpay-v2",
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

function renderOgHtml(origin, slug, data) {
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
<meta property="og:image" content="${DEFAULT_OG_IMAGE}">
<meta property="og:url" content="${url}">
<meta property="og:type" content="website">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${title}">
<meta name="twitter:description" content="${description}">
<meta name="twitter:image" content="${DEFAULT_OG_IMAGE}">
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

    // Fast pass-through: static files, multi-segment paths, reserved pages.
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

    // url.origin is whatever domain the crawler actually requested —
    // this is what makes the worker work on every domain unchanged.
    return new Response(renderOgHtml(url.origin, path, data), {
      headers: { "Content-Type": "text/html; charset=UTF-8" },
    });
  },
};
