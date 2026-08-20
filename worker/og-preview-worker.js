/**
 * Boltpay — OG Preview Worker
 *
 * Payment links are now root-level (pay.parvez.website/emily), not /u/emily.
 * This worker's route is set to match ALL paths on the zone, so it must
 * quickly pass through anything that isn't a bare single-segment slug —
 * static files, known app pages, and anything with a file extension.
 */

const SUPABASE_URL = "https://ohwzmxwsphsfzudmlins.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9od3pteHdzcGhzZnp1ZG1saW5zIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODYwMzE0MTksImV4cCI6MjEwMTYwNzQxOX0.frTl7qnDx7SK2IBMQxFCkKGe5u4XAQweRxPhQ-2r8rU";
const SITE_NAME = "Boltpay";
const DEFAULT_OG_IMAGE = "https://pay.parvez.website/assets/og-default.png";

// Same reserved list as dashboard.html / u.html — keep these in sync.
const RESERVED = new Set([
  "", "login", "register", "dashboard", "admin", "index", "404", "config",
  "u", "invoice-boltpay-v2", "dashboard-theme1-voltmeter",
  "dashboard-theme2-ledger", "dashboard-theme3-aurora", "dashboard-theme4-calm",
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

function renderOgHtml(slug, data) {
  const title = data?.display_name
    ? `Pay ${escapeHtml(data.display_name)} — ${SITE_NAME}`
    : `${SITE_NAME} — Lightning payment`;
  const description = `Send a secure Lightning payment via ${SITE_NAME}. Fast, low-fee, no account required to pay.`;
  const url = `https://pay.parvez.website/${encodeURIComponent(slug)}`;

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
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/^\/|\/$/g, "");

    // Fast pass-through for anything that isn't a bare single-segment slug:
    // static files (has a dot, e.g. config.js, og-default.png), multi-segment
    // paths, or a known reserved app page. No Supabase call, no delay.
    const looksLikeSlug = path.length > 0 && !path.includes("/") && !path.includes(".");
    if (!looksLikeSlug || RESERVED.has(path)) {
      return fetch(request);
    }

    const userAgent = request.headers.get("User-Agent") || "";
    if (!isCrawler(userAgent)) {
      // Real visitor — let Pages/_redirects serve the actual app page.
      return fetch(request);
    }

    // Crawler requesting a real slug — serve pre-rendered OG tags.
    const data = await fetchLinkPreviewData(path);
    if (!data || data.is_active === false) {
      return fetch(request); // let it fall through to the real 404 page
    }
    const html = renderOgHtml(path, data);

    return new Response(html, {
      headers: { "Content-Type": "text/html; charset=UTF-8" },
    });
  },
};
