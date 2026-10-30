// LND checkout: create an invoice straight on the merchant's own LND node
// (no route hints), like paycashapp.site.
//
// POST { slug, amountUSD, customerName?, deviceId? } -> { data: { paymentId } }
// Errors: { error: { message } }
//
// Runs only when app_settings.lnd_checkout_enabled is true AND the link's
// checkout_backend is 'lnd'. Otherwise it refuses.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { LndClient, lndConfig } from "../_shared/lnd.ts";
import { chargedAmount, parseUsd, usdToSats, withinLimits } from "../_shared/pricing.ts";
import { btcUsdRate } from "../_shared/rate.ts";
import { loadLndSettings } from "../_shared/settings.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function err(message: string, status: number) {
  return json({ error: { message } }, status);
}
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...CORS },
  });
}

function cleanName(v: unknown): string {
  const s = String(v ?? "").replace(/[^A-Za-z0-9 _.-]/g, "").trim().slice(0, 64);
  if (s) return s;
  const a = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  const r = crypto.getRandomValues(new Uint8Array(6));
  return "Customer-" + Array.from(r, (b) => a[b % a.length]).join("");
}
function cleanDevice(v: unknown): string | null {
  const s = String(v ?? "").trim();
  return /^[A-Za-z0-9-]{8,64}$/.test(s) ? s : null;
}

// A link's own min/max narrow the global limits; they never widen them.
function linkLimits(link: { min_usd?: unknown; max_usd?: unknown }, s: { minUsd: number; maxUsd: number }) {
  const lmin = Number(link.min_usd), lmax = Number(link.max_usd);
  const min = link.min_usd != null && lmin > 0 ? Math.max(s.minUsd, lmin) : s.minUsd;
  const max = link.max_usd != null && lmax > 0 ? Math.min(s.maxUsd, lmax) : s.maxUsd;
  return { min, max: Math.max(min, max) };
}

// GET ?slug= -> { data: { displayName, minUsd, maxUsd } } for the /pay amount
// page. Same gate as POST: 404 unless the flag is on and the link uses LND.
async function linkInfo(slug: string) {
  if (!/^[A-Za-z0-9][A-Za-z0-9-]{2,48}[A-Za-z0-9]$/.test(slug)) return err("Invalid payment link", 400);
  let settings;
  try {
    settings = await loadLndSettings(db);
  } catch {
    return err("Temporarily unavailable", 503);
  }
  if (!settings.enabled) return err("This payment method is not available", 404);
  const { data: rows, error } = await db.rpc("system_lnd_link_for_invoice", { p_slug: slug });
  const link = Array.isArray(rows) ? rows[0] : rows;
  if (error || !link || link.checkout_backend !== "lnd") return err("Payment link not found", 404);
  if (!link.is_active) return err("This payment link is no longer active", 410);
  const lim = linkLimits(link, settings);
  const quick = (Array.isArray(link.quick_amounts) ? link.quick_amounts : [])
    .map((q: unknown) => Number(q)).filter((q: number) => q >= lim.min && q <= lim.max);
  return json({ data: { displayName: link.display_name ?? slug, minUsd: lim.min, maxUsd: lim.max, quickAmounts: quick, note: link.note ?? null } });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method === "GET") return linkInfo(new URL(req.url).searchParams.get("slug") ?? "");
  if (req.method !== "POST") return err("Method not allowed", 405);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return err("Invalid JSON body", 400);
  }

  const slug = String(body.slug ?? "").trim();
  if (!/^[A-Za-z0-9][A-Za-z0-9-]{2,48}[A-Za-z0-9]$/.test(slug)) return err("Invalid payment link", 400);
  const amount = parseUsd(body.amountUSD ?? body.amount);
  if (amount === null) return err("Invalid amount", 400);

  let settings;
  try {
    settings = await loadLndSettings(db);
  } catch (e) {
    console.error((e as Error).message);
    return err("Temporarily unavailable", 503);
  }
  if (!settings.enabled) return err("This payment method is not available", 404);
  if (!withinLimits(amount, settings.minUsd, settings.maxUsd)) {
    return err(`Amount must be between $${settings.minUsd} and $${settings.maxUsd}`, 400);
  }

  const cfg = await lndConfig(db);
  if (!cfg) {
    console.error("LND_REST_URL / LND_INVOICE_MACAROON not set or invalid");
    return err("This payment method is not available right now", 503);
  }

  const { data: rows, error: linkErr } = await db.rpc("system_lnd_link_for_invoice", { p_slug: slug });
  const link = Array.isArray(rows) ? rows[0] : rows;
  if (linkErr || !link) return err("Payment link not found", 404);
  if (!link.is_active) return err("This payment link is no longer active", 410);
  if (link.checkout_backend !== "lnd") return err("This payment method is not available", 404);

  const lim = linkLimits(link, settings);
  if (!withinLimits(amount, lim.min, lim.max)) return err(`Amount must be between $${lim.min} and $${lim.max}`, 400);

  // One global customer markup (default +10%), not the per-link cost_percent.
  const charged = chargedAmount(amount, settings.markupPercent);
  if (charged > settings.maxUsd * 11) return err("This link's current price is too high to invoice", 400);

  // Same per-owner brake as create-invoice; fails closed.
  const since = new Date(Date.now() - 60_000).toISOString();
  const { count, error: rateErr } = await db
    .from("payments").select("id", { count: "exact", head: true })
    .eq("user_id", link.user_id).gte("created_at", since);
  if (rateErr) return err("Temporarily unavailable — please try again in a moment", 503);
  if ((count ?? 0) >= 30) return err("Too many invoices — please wait a moment and try again", 429);

  let rate: number;
  try {
    rate = await btcUsdRate();
  } catch (e) {
    console.error("rate:", (e as Error).message);
    return err("Price feed unavailable — please try again", 503);
  }
  const sats = usdToSats(charged, rate);

  const lnd = new LndClient(cfg);
  const paymentId = crypto.randomUUID();
  let inv, btcAddress: string | null = null;
  try {
    inv = await lnd.addInvoice(sats, `boltpay ${slug} ${paymentId.slice(0, 8)}`, settings.expirySec);
    if (settings.onchainFallback) {
      btcAddress = await lnd.newAddress().catch((e) => {
        console.error("newaddress:", (e as Error).message);
        return null;
      });
    }
  } catch (e) {
    console.error((e as Error).message);
    return err("Payment creation failed", 502);
  }

  const expiresAt = new Date(Date.now() + settings.expirySec * 1000).toISOString();
  const { error: insErr } = await db.from("payments").insert({
    id: paymentId,
    payment_link_id: link.link_id,
    user_id: link.user_id,
    backend: "lnd",
    method: "lightning",
    buyer_amount: amount,
    amount_requested: charged,
    status: "new",
    expires_at: expiresAt,
    customer_city: req.headers.get("cf-ipcity") || null,
    customer_country: req.headers.get("cf-ipcountry") || null,
    lightning_invoice: inv.paymentRequest,
    bolt11: inv.paymentRequest,
    lnd_r_hash: inv.rHashHex,
    amount_sats: sats,
    btc_usd_rate: rate,
    btc_address: btcAddress,
    customer_name: cleanName(body.customerName),
    device_id: cleanDevice(body.deviceId),
  });
  if (insErr) {
    // The LND invoice simply expires unpaid; nothing to clean up.
    console.error("insert:", insErr.message);
    return err("Payment creation failed", 500);
  }
  return json({ data: { paymentId } });
});
