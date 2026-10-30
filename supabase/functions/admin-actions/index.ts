// Admin-only actions: mark a payment settled, and close a withdrawal
// (reject, or mark paid after it was sent by hand). Never moves money.
import { notifyLndSettled } from "../_shared/alerts.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabaseAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

function normalizeOriginHost(value: string): string {
  const trimmed = value.trim().replace(/\/+$/, "");
  try { return new URL(trimmed).host.toLowerCase(); } catch { return trimmed.toLowerCase(); }
}
const STATIC_ORIGINS = (Deno.env.get("ALLOWED_ORIGINS") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
async function allowedHosts(): Promise<Set<string>> {
  const hosts = new Set<string>(STATIC_ORIGINS.map(normalizeOriginHost));
  try {
    const { data } = await supabaseAdmin.from("site_domains").select("hostname").eq("is_active", true);
    for (const d of data ?? []) if (d.hostname) hosts.add(String(d.hostname).toLowerCase());
  } catch { /* static list only */ }
  return hosts;
}
async function corsHeaders(req: Request): Promise<Record<string, string>> {
  const h: Record<string, string> = {
    "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
  const origin = req.headers.get("Origin");
  if (!origin) return h;
  let host = "";
  try { host = new URL(origin).host; } catch { return h; }
  if ((await allowedHosts()).has(host)) h["Access-Control-Allow-Origin"] = origin;
  return h;
}
function json(body: unknown, status = 200, cors: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...cors } });
}
Deno.serve(async (req) => {
  const cors = await corsHeaders(req);
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405, cors);
  const auth = req.headers.get("Authorization");
  if (!auth) return json({ error: "Unauthorized" }, 401, cors);
  const caller = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { global: { headers: { Authorization: auth } } });
  const { data: { user } } = await caller.auth.getUser();
  if (!user) return json({ error: "Invalid session" }, 401, cors);
  const { data: prof } = await supabaseAdmin.from("profiles").select("role").eq("id", user.id).single();
  if (prof?.role !== "admin") return json({ error: "Not authorized" }, 403, cors);

  let body: { action?: string; paymentId?: string; amountSettled?: number; withdrawalId?: string } = {};
  try { body = await req.json(); } catch { /* empty */ }

  if (body.action === "mark-settled") {
    if (!body.paymentId) return json({ error: "paymentId required" }, 400, cors);
    // The admin's own client, so is_admin() inside the RPC sees auth.uid().
    const { error } = await caller.rpc("admin_mark_payment", {
      p_payment_id: body.paymentId, p_status: "settled", p_amount_settled: body.amountSettled ?? null,
    });
    if (error) return json({ error: error.message }, 400, cors);
    const { data: p } = await supabaseAdmin.from("payments").select("user_id").eq("id", body.paymentId).single();
    if (p?.user_id) {
      const { error: qErr } = await supabaseAdmin.rpc("system_queue_withdrawal", { p_user_id: p.user_id });
      if (qErr) console.error("Auto-queue failed for", p.user_id, qErr.message);
    }
    await notifyLndSettled(supabaseAdmin, body.paymentId);
    return json({ status: "settled" }, 200, cors);
  }

  if (body.action === "reject" || body.action === "mark_paid_manual") {
    if (!body.withdrawalId) return json({ error: "withdrawalId required" }, 400, cors);
    const { data: w } = await supabaseAdmin.from("withdrawals").select("id, method").eq("id", body.withdrawalId).single();
    if (!w) return json({ error: "Not found" }, 404, cors);
    const next = body.action === "reject" ? "rejected" : "paid";
    const { data: claimed } = await supabaseAdmin.rpc("system_claim_withdrawal", {
      p_withdrawal_id: body.withdrawalId, p_next_status: next,
    });
    if (claimed !== true) return json({ error: "Already processed" }, 409, cors);
    if (next === "paid") {
      await supabaseAdmin.from("withdrawals").update({ admin_note: `Manually paid via ${w.method}` }).eq("id", body.withdrawalId);
    }
    return json({ status: next }, 200, cors);
  }
  return json({ error: "Unknown action" }, 400, cors);
});
