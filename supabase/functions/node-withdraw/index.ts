// node-withdraw: owner-only on-chain sends and Lightning payments from the
// node. Behind app_settings.node_withdraw_enabled (default false) and a
// per-spend step-up code sent to the admin Telegram (0113). Logic: _shared/node_withdraw.ts.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { sendOpsAlert, sendNodeWithdrawStepup } from "../_shared/alerts.ts";
import { LndWithdrawClient, withdrawConfig } from "../_shared/lnd_withdraw.ts";
import { handle } from "../_shared/node_withdraw.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

// These are Boltpay's confirmed live admin hosts. Keep them allowed even when
// ALLOWED_ORIGINS is configured for a different service; do not replace that
// shared setting (which could disrupt live Lightning checkout elsewhere).
const ORIGINS = new Set([
  "paycashapp.shop",
  "www.paycashapp.shop",
  ...(Deno.env.get("ALLOWED_ORIGINS") ?? "").split(",").map((s) => s.trim()).filter(Boolean)
    .map((s) => { try { return new URL(s).host.toLowerCase(); } catch { return s.toLowerCase(); } }),
]);

function cors(req: Request): Record<string, string> {
  const h: Record<string, string> = {
    "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
  const o = req.headers.get("Origin");
  try { if (o && ORIGINS.has(new URL(o).host.toLowerCase())) h["Access-Control-Allow-Origin"] = o; } catch { /* none */ }
  return h;
}

Deno.serve(async (req) => {
  const c = cors(req);
  const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...c } });
  if (req.method === "OPTIONS") return new Response(null, { headers: c });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const auth = req.headers.get("Authorization");
  if (!auth) return json({ error: "Unauthorized" }, 401);
  const caller = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { global: { headers: { Authorization: auth } } });
  const { data: { user } } = await caller.auth.getUser(auth.replace(/^Bearer\s+/i, ""));
  if (!user) return json({ error: "Invalid session" }, 401);
  const { data: prof } = await admin.from("profiles").select("role, telegram_chat_id").eq("id", user.id).single();

  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* empty */ }

  const r = await handle(user.id, prof?.role ?? null, body, {
    rpc: (fn, args) => admin.rpc(fn, args),
    setting: async (key) => (await admin.from("app_settings").select("value").eq("key", key).maybeSingle()).data?.value ?? null,
    lnd: async () => {
      const cfg = await withdrawConfig(admin);
      return cfg ? new LndWithdrawClient(cfg) : null;
    },
    stepUpSecret: Deno.env.get("NODE_WITHDRAW_STEPUP_SECRET") ?? SERVICE_ROLE_KEY,
    alert: (t) => sendOpsAlert(t),
    sendStepupCode: (t) => sendNodeWithdrawStepup(t, prof?.telegram_chat_id),
    pending: async (owner) => {
      // Server-side service-role read, only reached after owner+admin check.
      const { data, error } = await admin.from("node_withdrawals")
        .select("id,kind,payment_hash")
        .eq("actor_id", owner).eq("status", "reserved")
        .order("id", { ascending: true }).limit(25);
      if (error) throw new Error("pending withdrawal query failed");
      return (data ?? []) as Array<{ id: number; kind: string; payment_hash: string | null }>;
    },
  });
  return json(r.body, r.status);
});
