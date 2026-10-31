// node-withdraw: owner-only on-chain sends and Lightning payments from the
// node. Behind app_settings.node_withdraw_enabled (default false) and a
// step-up check that, for now, refuses every spend. Logic: _shared/node_withdraw.ts.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { sendOpsAlert } from "../_shared/alerts.ts";
import { LndWithdrawClient, withdrawConfig } from "../_shared/lnd_withdraw.ts";
import { handle, rejectAllStepUp } from "../_shared/node_withdraw.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

const ORIGINS = new Set((Deno.env.get("ALLOWED_ORIGINS") ?? "").split(",").map((s) => s.trim()).filter(Boolean)
  .map((s) => { try { return new URL(s).host.toLowerCase(); } catch { return s.toLowerCase(); } }));

function cors(req: Request): Record<string, string> {
  const h: Record<string, string> = {
    "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
  const o = req.headers.get("Origin");
  try { if (o && ORIGINS.has(new URL(o).host)) h["Access-Control-Allow-Origin"] = o; } catch { /* none */ }
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
  const { data: prof } = await admin.from("profiles").select("role").eq("id", user.id).single();

  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* empty */ }

  const r = await handle(user.id, prof?.role ?? null, body, {
    rpc: (fn, args) => admin.rpc(fn, args),
    setting: async (key) => (await admin.from("app_settings").select("value").eq("key", key).maybeSingle()).data?.value ?? null,
    lnd: async () => {
      const cfg = await withdrawConfig(admin);
      return cfg ? new LndWithdrawClient(cfg) : null;
    },
    verifyStepUp: rejectAllStepUp,
    alert: (t) => sendOpsAlert(t),
  });
  return json(r.body, r.status);
});
