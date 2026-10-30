/**
* Boltpay — OG Preview Worker
*
* Domain-agnostic: the preview URL is rebuilt from the incoming request,
* so one deployment serves every domain you attach it to.
*
* Per-model preview images: looks for assets/og/<slug>.png in the GitHub
* repo with a HEAD request. If that file exists, it's used; otherwise it
* falls back to og-default-v2.png. The HEAD result is cached so repeat
* crawls of the same slug don't re-check.
*/
const SUPABASE_URL = "https://ohwzmxwsphsfzudmlins.supabase.co";
// Custom (white-label) hostnames and the SaaS fallback host have no origin
// of their own: the static site is the Workers custom domain on the platform
// host. Pass-through fetches for any other hostname are re-pointed there, so
// fetch(request) on a customer domain serves the same files instead of 522.
const ASSET_HOST = "paycashapp.shop";
const PASSTHRU_HOSTS = new Set(["paycashapp.shop", "www.paycashapp.shop"]);
const nativeFetch = globalThis.fetch.bind(globalThis);
function fetch(input, init) {
const req = new Request(input, init);
const u = new URL(req.url);
if (u.protocol === "https:" && !PASSTHRU_HOSTS.has(u.hostname) && !u.hostname.endsWith(".supabase.co")) {
u.hostname = ASSET_HOST;
return nativeFetch(new Request(u.toString(), req));
}
return nativeFetch(req);
}
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9od3pteHdzcGhzZnp1ZG1saW5zIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODYwMzE0MTksImV4cCI6MjEwMTYwNzQxOX0.frTl7qnDx7SK2IBMQxFCkKGe5u4XAQweRxPhQ-2r8rU";
// og:site_name is the small grey line a chat app prints above the card.
// It used to say "Boltpay" on every domain, which told the payer nothing
// about where the link would take them. The hostname they are about to
// visit is more useful and is derived per request, so every domain
// labels itself correctly with no per-domain config.
// OG images are served from the site itself (public/assets/og/, deployed by
// Cloudflare Pages), NOT from raw.githubusercontent.com.
//
// They used to come from GitHub raw. The moment the repo was made private,
// raw.githubusercontent started returning 404 to unauthenticated clients —
// and WhatsApp/Telegram crawlers are unauthenticated. The per-slug image AND
// og-default.png both died at once, which is why no preview image appeared
// at all, not even the fallback.
//
// Serving from the origin removes that dependency entirely and follows
// whichever domain the link was actually shared on.
const OG_PATH = "/assets/og";
// Real pages and static files that must never be treated as a payment slug.
// Keep this in sync with the RESERVED list in 404.html and dashboard.html.
const RESERVED = new Set([
// "" is the site root, which is handled separately above; the rest
// mirror validate_link_slug() in the database exactly.
"",
'index','login','register','dashboard','admin','404','config','theme',
'assets','favicon','api','u','static','public',
'well-known','robots','sitemap','moderator','expired',
// Worker-only (not in validate_link_slug): the Lightning checkout page file.
'lnd-pay',
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
* Cached for an hour so a widely shared link doesn't trigger a HEAD
* request on every single crawl.
*/
async function resolveOgImage(origin, slug, ogImage) {
const candidate = `${origin}${OG_PATH}/${encodeURIComponent(slug)}.png`;
const fallback = `${origin}${OG_PATH}/og-default-v2.png`;

// 1. An explicit image on the link wins. The database constrains
//    payment_links.og_image to a bare filename, so it cannot escape
//    /assets/og/.
if (ogImage) {
return `${origin}${OG_PATH}/${encodeURIComponent(ogImage)}`;
}
// Cache key is versioned (v2). The old key still holds "0" for every slug
// from while GitHub raw was 404-ing, and those entries would keep forcing
// the fallback for up to an hour after this fix ships.
const cacheKey = new Request(`https://og-check.internal/v2/${encodeURIComponent(origin)}/${slug}`);
const cache = caches.default;
try {
const cached = await cache.match(cacheKey);
if (cached) {
const found = await cached.text();
return found === "1" ? candidate : generatedImage(origin, slug);
}
const head = await nativeFetch(candidate, { method: "HEAD" });
const exists = head.ok;
await cache.put(
cacheKey,
new Response(exists ? "1" : "0", {
headers: { "Cache-Control": "max-age=3600" },
})
);
return exists ? candidate : generatedImage(origin, slug);
} catch (e) {
console.error("OG image check failed:", e);
return fallback;
}
}

// 3. No file on disk: the og-image function draws one from the link's
// name. Same origin and ending in .png, both of which matter — some
// iMessage and WhatsApp builds refuse to scrape an og:image that is
// cross-origin or carries no image extension.
function generatedImage(origin, slug) {
return `${origin}/og-image/${encodeURIComponent(slug)}.png`;
}

/**
 * Proxy /og-image/<slug>.png to the Supabase function and hold the
 * result in Cloudflare's cache.
 *
 * That function loads a wasm rasteriser and a font on a cold start.
 * Crawlers wait roughly 2-3 seconds and then give up, so the first
 * render is the risky one and every render after it should never reach
 * Supabase at all. This cache is what makes that true.
 */
async function serveOgImage(request, url) {
const cache = caches.default;
const cacheKey = new Request(url.toString(), { method: "GET" });
const hit = await cache.match(cacheKey);
if (hit) return hit;

const slug = url.pathname.split("/").pop();
const res = await fetch(`${SUPABASE_URL}/functions/v1/og-image/${slug}`, {
headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${SUPABASE_ANON_KEY}` },
redirect: "follow",
});

if (!res.ok || !(res.headers.get("Content-Type") || "").startsWith("image/")) {
// Never cache a failure — a crawler would hold on to the broken result.
return fetch(`${url.origin}${OG_PATH}/og-default-v2.png`);
}

const out = new Response(res.body, res);
out.headers.set("Cache-Control", "public, max-age=31536000, immutable");
out.headers.set("Content-Type", "image/png");
await cache.put(cacheKey, out.clone());
return out;
}
function renderOgHtml(origin, slug, data, ogImage) {
const siteName = escapeHtml(new URL(origin).hostname);
const title = data?.display_name
? `Pay ${escapeHtml(data.display_name)}`
: "Pay with Boltpay";
const description =
"Secure Lightning checkout. Paid in seconds.";
const url = `${origin}/${encodeURIComponent(slug)}`;

return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>${title}</title>
<meta property="og:site_name" content="${siteName}">
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

/**
 * A domain registered as purpose='payment' should not serve the marketing
 * site at its root. index.html tried to handle this in JavaScript, so the
 * whole home page painted before anything redirected — and it gave up
 * entirely when no *other* domain was flagged is_primary_site, which is
 * exactly the state that produced the bug.
 *
 * Doing it here means the visitor never sees the wrong page at all.
 * Cached for 5 minutes, so a change in the admin panel takes effect
 * without a redeploy.
 */
async function resolveRootRedirect(host) {
const cacheKey = new Request(`https://domain-route.internal/v1/${host}`);
const cache = caches.default;
try {
const cached = await cache.match(cacheKey);
if (cached) {
const value = await cached.text();
return value === "-" ? null : value;
}
const res = await fetch(
`${SUPABASE_URL}/rest/v1/site_domains?select=hostname,purpose,is_primary_site,is_active&is_active=eq.true`,
{ headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${SUPABASE_ANON_KEY}` } },
);
if (!res.ok) return null;
const rows = await res.json();
const lower = host.toLowerCase();
const self = rows.find((d) => (d.hostname || "").toLowerCase() === lower);
let target = null;
// Only redirect a domain that is explicitly payment-only. Unregistered
// domains and 'site'/'both' domains are left alone.
if (self && self.purpose === "payment") {
const primary =
rows.find((d) => d.is_primary_site && (d.hostname || "").toLowerCase() !== lower) ||
rows.find((d) => (d.purpose === "site" || d.purpose === "both") &&
(d.hostname || "").toLowerCase() !== lower);
if (primary) target = `https://${primary.hostname}/`;
}
await cache.put(
cacheKey,
new Response(target || "-", { headers: { "Cache-Control": "max-age=300" } }),
);
return target;
} catch (e) {
console.error("domain routing lookup failed:", e);
return null;
}
}

function renderHomeOgHtml(origin) {
const siteName = escapeHtml(new URL(origin).hostname);
const title = "Boltpay \u2014 get paid in seconds";
const description =
"Share one payment link and get paid over Lightning. Secure checkout, daily statements, fast payouts.";
const image = `${origin}${OG_PATH}/og-home-v2.png`;

return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>${title}</title>
<meta property="og:site_name" content="${siteName}">
<meta property="og:title" content="${title}">
<meta property="og:description" content="${description}">
<meta property="og:image" content="${image}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:url" content="${origin}/">
<meta property="og:type" content="website">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${title}">
<meta name="twitter:description" content="${description}">
<meta name="twitter:image" content="${image}">
<meta http-equiv="refresh" content="0; url=${origin}/">
</head>
<body>
<p>Redirecting to <a href="${origin}/">${siteName}</a>\u2026</p>
</body>
</html>`;
}

// ---- Lightning (LND) checkout --------------------------------------------
// Same-origin proxy for the /pay/* pages, so the page's CSP stays
// connect-src 'self' and Cloudflare's city/country reach the function.
// Every function behind these is itself gated by lnd_checkout_enabled;
// with the flag off they answer 404/503 and nothing changes.
const LND_API = {
"api/lnd/link": { fn: "lnd-create-invoice", method: "GET", query: ["slug"] },
"api/lnd/invoice": { fn: "lnd-create-invoice", method: "POST" },
"api/lnd/status": { fn: "payment-status", method: "GET", query: ["id"] },
"api/lnd/event": { fn: "track-event", method: "POST" },
};
async function proxyLnd(request, url, route) {
if (request.method !== route.method) {
return new Response(JSON.stringify({ error: { message: "Method not allowed" } }), {
status: 405, headers: { "Content-Type": "application/json" },
});
}
const target = new URL(`${SUPABASE_URL}/functions/v1/${route.fn}`);
for (const k of route.query || []) {
const v = url.searchParams.get(k);
if (v !== null) target.searchParams.set(k, v);
}
const cf = request.cf || {};
const init = {
method: route.method,
headers: {
"Content-Type": "application/json",
apikey: SUPABASE_ANON_KEY,
Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
"User-Agent": request.headers.get("User-Agent") || "",
"cf-ipcity": cf.city || "",
"cf-ipcountry": cf.country || "",
},
};
if (route.method === "POST") init.body = (await request.text()).slice(0, 4096);
const res = await fetch(target.toString(), init);
const out = new Response(res.body, res);
out.headers.set("Cache-Control", "no-store");
return out;
}
// /pay/<slug>, /pay/i/<id>, /pay/i/<id>/success|expired all render the
// one static page; it reads the path itself.
// An unknown or inactive /pay/<slug> still renders the page (it shows a
// bilingual "Link not found"), but with a real 404 status so crawlers and
// link checkers see it as missing.
async function servePayPage(request, url) {
const page = await fetch(new Request(`${url.origin}/lnd-pay`, { headers: request.headers }));
const parts = url.pathname.replace(/^\/+|\/+$/g, "").split("/");
let missing = false;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
if (parts.length === 2 && parts[1].toLowerCase() === "expired") {
// Generic "invoice expired" landing page, like /pay/expired elsewhere.
return page;
} else if (parts[1] === "i") {
// /pay/i/<uuid>[/success|/expired|/btc] is an invoice; anything else is missing.
const tail = parts[3];
if (parts.length < 3 || parts.length > 4 || !UUID_RE.test(parts[2]) || (tail && tail !== "success" && tail !== "expired" && tail !== "btc")) {
missing = true;
} else {
const api = new URL(`${url.origin}/api/lnd/status?id=${encodeURIComponent(parts[2])}`);
try {
const res = await proxyLnd(new Request(api.toString(), { headers: request.headers }), api, LND_API["api/lnd/status"]);
missing = res.status === 404 || res.status === 400;
} catch (e) { missing = false; }
}
} else if (parts.length !== 2) {
// /pay/invoice/<x>, /pay/a/b/c ... are not routes.
missing = true;
} else {
const api = new URL(`${url.origin}/api/lnd/link?slug=${encodeURIComponent(parts[1])}`);
try {
const res = await proxyLnd(new Request(api.toString(), { headers: request.headers }), api, LND_API["api/lnd/link"]);
missing = res.status === 404;
} catch (e) { missing = false; }
}
if (!missing) return page;
const out = new Response(page.body, { status: 404, headers: page.headers });
out.headers.set("Cache-Control", "no-store");
return out;
}

// ---- Custom (white-label) domains ----------------------------------------
// An active custom hostname (site_domains.kind = 'custom') serves only its
// owner's links, never /admin or /moderator, and is branded via
// /api/domain-info. Platform and unknown hosts resolve to null, so their
// behaviour is unchanged. Cached for 5 minutes per host.
async function rpc(fn, args) {
const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
method: "POST",
headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${SUPABASE_ANON_KEY}`, "Content-Type": "application/json" },
body: JSON.stringify(args),
});
if (!res.ok) throw new Error(`rpc ${fn} ${res.status}`);
return res.json();
}
async function customDomainInfo(host) {
const cacheKey = new Request(`https://domain-info.internal/v1/${host.toLowerCase()}`);
const cache = caches.default;
try {
const cached = await cache.match(cacheKey);
if (cached) { const t = await cached.text(); return t === "-" ? null : JSON.parse(t); }
const info = await rpc("domain_info", { p_host: host });
await cache.put(cacheKey, new Response(info ? JSON.stringify(info) : "-", { headers: { "Cache-Control": "max-age=300" } }));
return info || null;
} catch (e) {
console.error("domain_info lookup failed:", e);
return null;
}
}
async function customDomainAllowsSlug(host, slug) {
try { return (await rpc("custom_domain_allows_slug", { p_host: host, p_slug: slug })) !== false; }
catch (e) { return true; }
}
function notFound() {
return new Response(JSON.stringify({ error: { message: "Not found" } }), {
status: 404, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
});
}

export default {
                            async fetch(request) {
                            const url = new URL(request.url);
                            const path = url.pathname.replace(/^\/|\/$/g, "");

if (path === "api/domain-info") {
const info = await customDomainInfo(url.hostname);
return new Response(JSON.stringify({ data: info }), {
headers: { "Content-Type": "application/json", "Cache-Control": "public, max-age=300" },
});
}
const custom = await customDomainInfo(url.hostname);
if (custom) {
const lower = path.toLowerCase();
if (["admin", "admin.html", "moderator", "moderator.html"].includes(lower)) return notFound();
if (path === "") return Response.redirect(`${url.origin}/login`, 302);
const slug = path.startsWith("pay/") && path.split("/").length === 2 && path.split("/")[1] !== "i" ? path.split("/")[1]
: path === "api/lnd/link" ? (url.searchParams.get("slug") || "") : null;
if (slug && slug.toLowerCase() !== "expired" && !(await customDomainAllowsSlug(url.hostname, slug))) {
return path.startsWith("pay/")
? new Response((await fetch(new Request(`${url.origin}/lnd-pay`, { headers: request.headers }))).body, { status: 404, headers: { "Content-Type": "text/html; charset=UTF-8", "Cache-Control": "no-store" } })
: notFound();
}
}

if (LND_API[path]) return proxyLnd(request, url, LND_API[path]);
// Bare /pay stays an ordinary slug; only /pay/... is the checkout.
if (path.startsWith("pay/")) return servePayPage(request, url);

// Generated preview images.
if (path.startsWith("og-image/") && path.endsWith(".png")) {
return serveOgImage(request, url);
}

// A payment-only domain serves payment links and nothing else. The
// root already redirected, but every other page of the app was still
// reachable there — /admin, /login, /dashboard, /register all served
// happily from the payment host.
//
// That is not an authentication hole (those pages check the session
// themselves, and Supabase enforces RLS regardless of which hostname
// asked). It is a surface problem: the admin panel should not be
// discoverable, fingerprintable or phishable on a hostname handed out
// to customers, and a login form on a payment domain is exactly the
// shape a convincing phishing page would take.
//
// Sends them to the same place the root redirect does, so there is one
// answer to "where does the real site live" rather than two.
const APP_ONLY_PATHS = new Set([
"admin", "login", "register", "dashboard", "moderator",
"admin.html", "login.html", "register.html", "dashboard.html", "moderator.html",
]);
if (APP_ONLY_PATHS.has(path.toLowerCase())) {
const target = await resolveRootRedirect(url.hostname);
// Only redirects when resolveRootRedirect says this host is
// payment-only AND a site domain exists to send them to. On a
// 'both' domain, or with nowhere to point, the page serves as
// normal — no behaviour change for a single-domain setup.
if (target) return Response.redirect(target, 302);
}

// Root of a payment-only domain: send visitors to the real site before
// any of the marketing page is fetched.
if (path === "") {
const target = await resolveRootRedirect(url.hostname);
if (target) return Response.redirect(target, 302);

// Home-page link preview. index.html carries no og: tags, because a
// static file cannot know which domain it is being served from and any
// value baked in would be a guess that goes stale on the next domain
// change. Built here from the real hostname instead.
if (isCrawler(request.headers.get("User-Agent") || "")) {
return new Response(renderHomeOgHtml(url.origin), {
headers: { "Content-Type": "text/html; charset=UTF-8" },
});
}
return fetch(request);
}
                            // Fast pass-through: static files, multi-segment paths, reserved pages.
                            const looksLikeSlug =
                            path.length > 0 && !path.includes("/") && !path.includes(".");
                            if (!looksLikeSlug || RESERVED.has(path.toLowerCase())) {
                            return fetch(request);
                            }
                            if (!isCrawler(request.headers.get("User-Agent") || "")) {
                            return fetch(request);
                            }
                            const data = await fetchLinkPreviewData(path);
                            if (!data || data.is_active === false) {
                            return fetch(request);
                            }
                            const ogImage = await resolveOgImage(url.origin, path, data.og_image);
                            return new Response(renderOgHtml(url.origin, path, data, ogImage), {
                            headers: { "Content-Type": "text/html; charset=UTF-8" },
                            });
                            },
                            };
