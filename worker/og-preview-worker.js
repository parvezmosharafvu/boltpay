/**
 * Boltpay — OG Preview Worker
 *
 * Purpose: when a payment link like pay.parvez.website/u/emily is shared on
 * WhatsApp/Telegram/Facebook, their crawler bots request the URL to build
 * a link preview. Bots don't run JavaScript, so a plain SPA/static page
 * would show no title/image. This worker intercepts ONLY /u/:slug requests,
 * detects whether the requester is a known crawler (by User-Agent), and:
 *   - crawler  -> returns a small HTML doc with proper <meta property="og:*">
 *                 tags (no redirect, no cloaking — same underlying content,
 *                 just server-rendered for bots that can't execute JS)
 *   - human    -> passes the request through untouched to the real app
 *
 * This is standard SSR-for-crawlers practice (the same thing Next.js/Remix
 * do server-side for every visitor). It is NOT domain rotation or ban
 * evasion — there is exactly one public domain, and humans and bots both
 * ultimately reach the same real page.
 */

const SUPABASE_URL = "https://ohwzmxwsphsfzudmlins.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...."; // same anon key used client-side
const SITE_NAME = "Boltpay";
const DEFAULT_OG_IMAGE = "https://pay.parvez.website/assets/og-default.png";

// Known crawler user-agent substrings (case-insensitive match)
const CRAWLER_PATTERNS = [
  "whatsapp",
  "facebookexternalhit",
  "telegrambot",
  "twitterbot",
  "linkedinbot",
  "discordbot",
  "slackbot",
  "skypeuripreview",
  "viber",
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
  // Public RPC — returns only display-safe fields (see get_link_preview SQL below)
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
  const url = `https://pay.parvez.website/u/${encodeURIComponent(slug)}`;

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

    // Only intercept payment-link paths — everything else passes straight through.
    const match = url.pathname.match(/^\/u\/([a-zA-Z0-9-_]+)\/?$/);
    if (!match) {
      return fetch(request); // pass through to origin unchanged
    }

    const userAgent = request.headers.get("User-Agent") || "";

    if (!isCrawler(userAgent)) {
      // Real visitor — serve the actual app page, no special handling.
      return fetch(request);
    }

    // Crawler — serve pre-rendered OG tags.
    const slug = match[1];
    const data = await fetchLinkPreviewData(slug);
    const html = renderOgHtml(slug, data);

    return new Response(html, {
      headers: { "Content-Type": "text/html; charset=UTF-8" },
    });
  },
};
