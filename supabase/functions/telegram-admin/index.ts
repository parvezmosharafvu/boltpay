// Admin-only Telegram bot tools: status, re-register webhook, send a test.
// The bot token and webhook secret never leave the server.
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
async function tg(token: string, method: string, body?: unknown) {
  const r = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body ?? {}),
  });
  return await r.json().catch(() => ({ ok: false, description: `HTTP ${r.status}` }));
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
  const { data: prof } = await supabaseAdmin.from("profiles").select("role, telegram_chat_id").eq("id", user.id).single();
  if (prof?.role !== "admin") return json({ error: "Not authorized" }, 403, cors);

  let body: { action?: string } = {};
  try { body = await req.json(); } catch { /* empty */ }
  const token = Deno.env.get("ALERT_TELEGRAM_BOT_TOKEN");
  if (!token) return json({ error: "Bot token is not configured / বট টোকেন সেট করা নেই" }, 400, cors);

  if (body.action === "status") {
    const me = await tg(token, "getMe");
    const wh = await tg(token, "getWebhookInfo");
    const { count } = await supabaseAdmin.from("profiles").select("id", { count: "exact", head: true }).not("telegram_chat_id", "is", null);
    return json({
      ok: true,
      bot: me?.result?.username ?? null,
      webhook_set: !!wh?.result?.url,
      webhook_points_here: String(wh?.result?.url ?? "").startsWith(`${SUPABASE_URL}/functions/v1/telegram-webhook`),
      pending_updates: wh?.result?.pending_update_count ?? 0,
      last_error: wh?.result?.last_error_message ?? null,
      linked_users: count ?? 0,
    }, 200, cors);
  }
  if (body.action === "resync") {
    const secret = Deno.env.get("TELEGRAM_WEBHOOK_SECRET");
    if (!secret) return json({ error: "Webhook secret is not configured / ওয়েবহুক সিক্রেট সেট করা নেই" }, 400, cors);
    const r = await tg(token, "setWebhook", {
      url: `${SUPABASE_URL}/functions/v1/telegram-webhook`,
      secret_token: secret,
      allowed_updates: ["message"],
    });
    const me = await tg(token, "getMe");
    if (me?.result?.username) {
      await supabaseAdmin.from("app_settings").upsert({ key: "telegram_bot_username", value: me.result.username });
    }
    return r?.ok
      ? json({ ok: true, msg: "Webhook re-registered / ওয়েবহুক আবার নিবন্ধিত হয়েছে" }, 200, cors)
      : json({ error: r?.description ?? "setWebhook failed" }, 502, cors);
  }
  if (body.action === "test") {
    const chat = prof?.telegram_chat_id ?? Deno.env.get("ALERT_TELEGRAM_CHAT_ID");
    if (!chat) return json({ error: "Connect your own Telegram first / আগে নিজের টেলিগ্রাম যুক্ত করুন" }, 400, cors);
    const r = await tg(token, "sendMessage", { chat_id: chat, text: "Boltpay test message ✅ / পরীক্ষামূলক বার্তা" });
    return r?.ok
      ? json({ ok: true, msg: "Test message sent / পরীক্ষামূলক বার্তা পাঠানো হয়েছে" }, 200, cors)
      : json({ error: r?.description ?? "sendMessage failed" }, 502, cors);
  }
  return json({ error: "Unknown action" }, 400, cors);
});
