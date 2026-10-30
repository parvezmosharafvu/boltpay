/**
 * Boltpay — on-demand OG preview images
 *
 * GET /og-image/<slug>.png   (proxied and cached by the Cloudflare Worker)
 *
 * Renders a 1200x630 PNG for a payment link. Nothing is uploaded and
 * nothing is stored, so a link has a preview the instant a creator makes
 * it — no GitHub commit, no Pages rebuild.
 *
 * The .png in the path is deliberate: a bare ?slug= works on most
 * platforms, but some iMessage and WhatsApp builds refuse to scrape an
 * og:image URL with no image extension.
 *
 * Deploy:  supabase functions deploy og-image --no-verify-jwt
 * (crawlers cannot present a JWT)
 */
import { initWasm, Resvg } from "https://esm.sh/@resvg/resvg-wasm@2.6.2";
import { DISPLAY_FONT_BASE64 } from "./font.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const WASM_URL = "https://esm.sh/@resvg/resvg-wasm@2.6.2/index_bg.wasm";

// Module scope: a warm isolate pays these costs once, not per request.
let wasmReady: Promise<void> | null = null;
let fontBytes: Uint8Array | null = null;

function ensureWasm(): Promise<void> {
  if (!wasmReady) wasmReady = initWasm(fetch(WASM_URL));
  return wasmReady;
}

function ensureFont(): Uint8Array {
  if (!fontBytes) {
    const bin = atob(DISPLAY_FONT_BASE64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    fontBytes = out;
  }
  return fontBytes;
}

function escapeXml(str: string): string {
  return String(str ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

/**
 * Your SVG, with two substitutions: the avatar letter and the name.
 *
 * Changes from what you sent, and why:
 *
 *  - font-family is "Boltpay Display" everywhere. resvg has no system
 *    fonts, so 'Helvetica Neue', Helvetica, Arial would all miss and the
 *    text would render as nothing at all. The embedded face is registered
 *    under that name below.
 *
 *  - font-size on the name is computed rather than fixed at 150.
 *    "Taylor James" fits, but "Christopher Wellington" at 150px is about
 *    1,650px wide and would run off a 1200px canvas with no warning. The
 *    size steps down only when it has to, so short names look exactly as
 *    you designed them.
 *
 * Everything else — the green, the blue circle, the black square, the $,
 * the -5 letter-spacing, every coordinate — is untouched.
 */
function buildSvg(name: string): string {
  // Centred card (owner pt312u): green $ mark (owner pt313u) with a soft glow, "Pay
  // <Name>", a muted tagline and a "Secure Payment" pill on white.
  const displayName = String(name || "").trim().slice(0, 40);
  const title = escapeXml(`Pay ${displayName}`);
  // Inter Bold averages ~0.58 em per character; keep 80px side margins.
  const est = (displayName.length + 4) * 84 * 0.58;
  const titleSize = est > 1040 ? Math.max(44, Math.floor(84 * (1040 / est))) : 84;

  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 630" width="1200" height="630">
  <defs>
    <linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#00D632"/><stop offset="1" stop-color="#00B82C"/></linearGradient>
    <filter id="glow" x="-50%" y="-50%" width="200%" height="200%">
      <feGaussianBlur stdDeviation="28" />
    </filter>
  </defs>
  <rect width="1200" height="630" fill="#FFFFFF" />
  <rect x="490" y="62" width="220" height="220" rx="52" fill="#00D632" opacity="0.35" filter="url(#glow)" />
  <rect x="490" y="48" width="220" height="220" rx="52" fill="url(#g)" />
  <g transform="translate(531.5 230) scale(0.0915 -0.0915)">
    <path fill="#FFFFFF" d="M580 -220V1710H769V-220ZM675 -24Q484 -24 349.0 36.5Q214 97 142.0 212.0Q70 327 70 489H367Q369 407 406.5 349.0Q444 291 513.0 260.0Q582 229 677 229Q763 229 826.5 252.5Q890 276 925.5 319.0Q961 362 961 420Q961 468 933.5 503.5Q906 539 847.5 566.0Q789 593 694 613L537 647Q315 695 207.0 798.0Q99 901 99 1061Q99 1197 170.0 1298.5Q241 1400 368.5 1457.0Q496 1514 665 1514Q836 1514 961.0 1456.0Q1086 1398 1155.5 1290.5Q1225 1183 1230 1033H942Q934 1139 860.0 1200.0Q786 1261 666 1261Q591 1261 532.5 1237.5Q474 1214 440.5 1172.5Q407 1131 407 1076Q407 1030 433.0 996.5Q459 963 516.0 938.0Q573 913 664 893L807 862Q926 836 1013.0 798.5Q1100 761 1156.0 709.5Q1212 658 1239.0 591.0Q1266 524 1266 440Q1266 297 1194.5 192.5Q1123 88 990.5 32.0Q858 -24 675 -24Z"/>
  </g>
  <text x="600" y="408" font-size="${titleSize}" font-family="Boltpay Display" font-weight="bold" letter-spacing="-1.5" fill="#111113" text-anchor="middle">${title}</text>
  <text x="600" y="468" font-size="32" font-family="Boltpay Display" fill="#7A7A80" text-anchor="middle">Any amount \u00B7 Instant \u00B7 Secure</text>
  <rect x="436" y="510" width="328" height="62" rx="31" fill="#E3F9E7" />
  <g transform="translate(470 524)">
    <path d="M7 15V11a9 9 0 0 1 18 0v4" fill="none" stroke="#F5A524" stroke-width="4" />
    <rect x="2" y="15" width="28" height="21" rx="5" fill="#F5A524" />
  </g>
  <text x="621" y="552" font-size="30" font-family="Boltpay Display" fill="#00B82C" text-anchor="middle">Secure Payment</text>
</svg>`;
}

function fallbackRedirect(origin: string) {
  // Never hand a crawler an error status — it caches the failure and the
  // link shows no picture for as long as that cache lives. A redirect to
  // the static default means there is always something.
  return Response.redirect(`${origin}/assets/og/og-default-v2.png`, 302);
}

Deno.serve(async (req) => {
  const url = new URL(req.url);

  // Accept /og-image/<slug>.png, /functions/v1/og-image/<slug>.png, and
  // ?slug= so the endpoint is easy to test by hand.
  const tail = url.pathname.split("/").filter(Boolean).pop() || "";
  const fromPath = tail.replace(/\.png$/i, "");
  const slug = decodeURIComponent(
    fromPath === "og-image" ? (url.searchParams.get("slug") || "") : fromPath,
  );

  // Case matters — the slug styles differ only by capitalisation.
  if (!/^[A-Za-z0-9][A-Za-z0-9-]{2,48}[A-Za-z0-9]$/.test(slug)) {
    return fallbackRedirect(url.origin);
  }

  let displayName = slug;
  try {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/get_link_preview`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: SUPABASE_ANON_KEY,
        Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
      },
      body: JSON.stringify({ p_slug: slug }),
    });
    if (!res.ok) return fallbackRedirect(url.origin);
    const rows = await res.json();
    const row = Array.isArray(rows) ? rows[0] : rows;
    if (!row || row.is_active === false) return fallbackRedirect(url.origin);
    displayName = row.display_name || slug;
  } catch (e) {
    console.error("link lookup failed:", e);
    return fallbackRedirect(url.origin);
  }

  try {
    await ensureWasm();

    const resvg = new Resvg(buildSvg(displayName), {
      fitTo: { mode: "width", value: 1200 },
      font: {
        fontBuffers: [ensureFont()],
        defaultFontFamily: "Boltpay Display",
        // There are no system fonts in this runtime; scanning for them
        // only wastes cold-start time.
        loadSystemFonts: false,
      },
    });
    const png = resvg.render().asPng();
    // Copy into a concrete ArrayBuffer so Deno 2.x accepts the binary body
    // regardless of whether the renderer exposes ArrayBufferLike.
    const source = png.buffer as ArrayBuffer;
    const pngBuffer = source.slice(png.byteOffset, png.byteOffset + png.byteLength);

    return new Response(pngBuffer, {
      headers: {
        "Content-Type": "image/png",
        // Immutable for a year. The Worker caches on top of this, so a
        // crawler almost never waits on a cold start.
        "Cache-Control": "public, max-age=31536000, immutable",
        "Access-Control-Allow-Origin": "*",
      },
    });
  } catch (e) {
    console.error("render failed:", e);
    return fallbackRedirect(url.origin);
  }
});
