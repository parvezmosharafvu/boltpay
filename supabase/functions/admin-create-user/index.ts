// Admin-only: create a user account that starts approved.
// The caller must be an admin (checked with their own JWT via is_admin()).
// Self-registration with admin approval keeps working as before.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

let originCache: { at: number; hosts: Set<string> } | null = null;
async function allowedHosts(): Promise<Set<string>> {
  if (originCache && Date.now() - originCache.at < 60_000) return originCache.hosts;
  const hosts = new Set<string>(["paycashapp.shop"]);
  const { data } = await admin.from("site_domains").select("hostname").eq("is_active", true);
  for (const r of data ?? []) if (r.hostname) hosts.add(String(r.hostname).toLowerCase());
  originCache = { at: Date.now(), hosts };
  return hosts;
}
async function cors(req: Request): Promise<Record<string, string>> {
  const origin = req.headers.get("origin") ?? "";
  const h: Record<string, string> = {
    "Access-Control-Allow-Headers": "authorization, content-type, apikey, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
  try {
    const host = new URL(origin).host.toLowerCase();
    const hosts = await allowedHosts();
    if (hosts.has(host) || [...hosts].some((d) => host.endsWith("." + d))) h["Access-Control-Allow-Origin"] = origin;
  } catch { /* no origin */ }
  return h;
}

Deno.serve(async (req) => {
  const ch = await cors(req);
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...ch, "Content-Type": "application/json" } });
  if (req.method === "OPTIONS") return new Response(null, { headers: ch });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const auth = req.headers.get("authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return json({ error: "Not signed in" }, 401);
  const caller = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: auth } }, auth: { persistSession: false },
  });
  const { data: isAdmin, error: adminErr } = await caller.rpc("is_admin");
  if (adminErr || isAdmin !== true) return json({ error: "Not authorized" }, 403);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "Bad JSON" }, 400); }
  const email = String(body.email ?? "").trim().toLowerCase();
  const password = String(body.password ?? "");
  const displayName = String(body.display_name ?? "").trim().slice(0, 80);
  const phone = String(body.phone ?? "").trim().slice(0, 32);
  const telegram = String(body.telegram_username ?? "").trim().replace(/^@/, "").slice(0, 64);
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ error: "Invalid email" }, 400);
  if (password.length < 8) return json({ error: "Password must be at least 8 characters" }, 400);

  const { data: created, error: createErr } = await admin.auth.admin.createUser({
    email, password, email_confirm: true,
    user_metadata: { display_name: displayName || email.split("@")[0], phone, telegram_username: telegram },
  });
  if (createErr || !created?.user) return json({ error: createErr?.message ?? "Create failed" }, 400);

  const { error: finErr } = await caller.rpc("admin_finalize_created_user", { p_user_id: created.user.id });
  if (finErr) return json({ error: "Account created but approval failed: " + finErr.message, user_id: created.user.id }, 500);
  return json({ ok: true, user_id: created.user.id, email });
});
