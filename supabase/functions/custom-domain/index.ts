// Admin-only custom (white-label) domains via Cloudflare for SaaS.
// add | check | reprovision | set_status | remove. The Cloudflare token
// (CF_SAAS_API_TOKEN, scoped to SSL and Certificates on the SaaS zone)
// lives only in function secrets; zone id / CNAME target have defaults.
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

const HOST_RE = /^(?=.{4,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/;
type CfHost = {
  id: string; hostname: string; status: string;
  ssl?: { status?: string; validation_records?: unknown[]; validation_errors?: { message: string }[] };
  ownership_verification?: unknown; ownership_verification_http?: unknown;
  verification_errors?: string[];
};

async function cf(method: string, path: string, body?: unknown) {
  const token = Deno.env.get("CF_SAAS_API_TOKEN");
  // Zone id and CNAME target are not secrets; env overrides the defaults.
  const zone = Deno.env.get("CF_SAAS_ZONE_ID") ?? "824828c48c7a721f01ac5f3684078461";
  if (!token || !zone) throw new Error("Cloudflare for SaaS is not configured / Cloudflare for SaaS সেট করা নেই");
  const r = await fetch(`https://api.cloudflare.com/client/v4/zones/${zone}/custom_hostnames${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || j.success === false) {
    const msg = (j.errors ?? []).map((e: { message: string }) => e.message).join("; ") || `HTTP ${r.status}`;
    throw new Error(`Cloudflare: ${msg}`);
  }
  return j.result as CfHost;
}

// Map a Cloudflare custom hostname onto our row.
function fromCf(h: CfHost) {
  const ssl = h.ssl?.status ?? null;
  const live = h.status === "active" && ssl === "active";
  const errs = [...(h.verification_errors ?? []), ...(h.ssl?.validation_errors ?? []).map((e) => e.message)];
  return {
    cf_hostname_id: h.id,
    ssl_status: ssl,
    status: live ? "active" : (h.status === "blocked" || h.status === "moved" ? "failed" : "provisioning"),
    is_active: live,
    verification: {
      cname_target: Deno.env.get("CF_SAAS_CNAME_TARGET") ?? "fallback.paycashapp.shop",
      ownership: h.ownership_verification ?? null,
      ownership_http: h.ownership_verification_http ?? null,
      ssl_records: h.ssl?.validation_records ?? [],
    },
    last_error: errs.length ? errs.join("; ").slice(0, 500) : null,
    last_checked_at: new Date().toISOString(),
  };
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

  let body: { action?: string; id?: string; hostname?: string; owner_email?: string; brand_name?: string; status?: string } = {};
  try { body = await req.json(); } catch { /* empty */ }

  const { data: flag } = await supabaseAdmin.from("app_settings").select("value").eq("key", "custom_domains_enabled").maybeSingle();
  if (flag?.value !== true) {
    return json({ error: "Custom domains are turned off / কাস্টম ডোমেইন বন্ধ আছে" }, 409, cors);
  }

  try {
    if (body.action === "add") {
      const hostname = String(body.hostname ?? "").trim().toLowerCase().replace(/^https?:\/\//, "").replace(/\/.*$/, "");
      if (!HOST_RE.test(hostname)) return json({ error: "Invalid hostname / ভুল হোস্টনেম" }, 400, cors);
      const { data: owner } = await supabaseAdmin.from("profiles").select("id").ilike("email", String(body.owner_email ?? "").trim()).maybeSingle();
      if (!owner) return json({ error: "User not found / ইউজার পাওয়া যায়নি" }, 404, cors);
      const { data: platform } = await supabaseAdmin.from("site_domains").select("hostname").eq("kind", "platform");
      if ((platform ?? []).some((d) => hostname === d.hostname || hostname.endsWith("." + d.hostname))) {
        return json({ error: "That hostname belongs to the platform / এটি প্ল্যাটফর্মের ডোমেইন" }, 400, cors);
      }
      const { data: row, error } = await supabaseAdmin.from("site_domains").insert({
        hostname, purpose: "both", kind: "custom", owner_id: owner.id,
        brand_name: (body.brand_name ?? "").trim().slice(0, 60) || null,
        status: "pending", is_active: false,
      }).select("id").single();
      if (error) return json({ error: error.code === "23505" ? "Already registered / আগেই যোগ করা আছে" : error.message }, 400, cors);
      try {
        const h = await cf("POST", "", { hostname, ssl: { method: "http", type: "dv" } });
        await supabaseAdmin.from("site_domains").update(fromCf(h)).eq("id", row.id);
      } catch (e) {
        await supabaseAdmin.from("site_domains").update({ status: "failed", last_error: String((e as Error).message).slice(0, 500) }).eq("id", row.id);
      }
      return json({ ok: true, id: row.id }, 200, cors);
    }

    if (!body.id) return json({ error: "Missing id" }, 400, cors);
    const { data: d } = await supabaseAdmin.from("site_domains").select("*").eq("id", body.id).eq("kind", "custom").maybeSingle();
    if (!d) return json({ error: "Not found" }, 404, cors);

    if (body.action === "check") {
      if (!d.cf_hostname_id) return json({ ok: true, status: d.status }, 200, cors);
      const h = await cf("GET", `/${d.cf_hostname_id}`);
      const upd = fromCf(h);
      if (d.status === "disabled") { upd.status = "disabled"; upd.is_active = false; }
      await supabaseAdmin.from("site_domains").update({ ...upd, activated_at: upd.is_active && !d.activated_at ? new Date().toISOString() : d.activated_at }).eq("id", d.id);
      return json({ ok: true, status: upd.status, ssl_status: upd.ssl_status }, 200, cors);
    }
    if (body.action === "reprovision") {
      const h = d.cf_hostname_id
        ? await cf("PATCH", `/${d.cf_hostname_id}`, { ssl: { method: "http", type: "dv" } })
        : await cf("POST", "", { hostname: d.hostname, ssl: { method: "http", type: "dv" } });
      await supabaseAdmin.from("site_domains").update(fromCf(h)).eq("id", d.id);
      return json({ ok: true }, 200, cors);
    }
    if (body.action === "set_status") {
      if (body.status === "disabled") {
        await supabaseAdmin.from("site_domains").update({ status: "disabled", is_active: false }).eq("id", d.id);
      } else if (body.status === "active") {
        // Re-enable: re-read Cloudflare; it only goes live if Cloudflare says active.
        const h = d.cf_hostname_id ? await cf("GET", `/${d.cf_hostname_id}`) : null;
        await supabaseAdmin.from("site_domains").update(h ? fromCf(h) : { status: "pending" }).eq("id", d.id);
      } else return json({ error: "Bad status" }, 400, cors);
      return json({ ok: true }, 200, cors);
    }
    if (body.action === "remove") {
      if (d.cf_hostname_id) { try { await cf("DELETE", `/${d.cf_hostname_id}`); } catch { /* already gone */ } }
      // Row kept for history, renamed so the hostname can be added again.
      await supabaseAdmin.from("site_domains").update({
        status: "removed", is_active: false, cf_hostname_id: null,
        hostname: `${d.hostname}#removed-${Date.now()}`,
      }).eq("id", d.id);
      return json({ ok: true }, 200, cors);
    }
    return json({ error: "Unknown action" }, 400, cors);
  } catch (e) {
    return json({ error: String((e as Error).message).slice(0, 500) }, 502, cors);
  }
});
