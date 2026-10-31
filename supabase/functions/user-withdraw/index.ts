import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabaseAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
// Only browser calls need CORS (server-to-server callers like
// pg_cron ignore these headers entirely). The allowed-origin list is read
// from the site_domains table — the same registry the admin panel manages —
// so adding a domain in the admin panel enables it here within one cache
// window, with no secret change and no redeploy. The optional ALLOWED_ORIGINS
// secret is merged on top (comma-separated; accepts full URLs or bare hosts).
/**
* A CORS host, normalized exactly one way everywhere it is used.
*
* ALLOWED_ORIGINS can hold a full URL ("https://pay.example.com") or a
* bare host ("pay.example.com"); the database's site_domains.hostname is
* always bare. The normal path already reduced everything to bare,
* lowercase hosts before comparing — but the fallback taken when the
* database lookup fails returned STATIC_ORIGINS unnormalized. With a
* full-URL secret, that meant the working path compared "pay.example.com"
* while the fallback compared "https://pay.example.com": never equal, so
* every browser request lost its CORS header for as long as the fallback
* was active. Not an auth bypass — an availability bug that only showed
* up during a database hiccup, which is exactly when a payout or a
* payment matters most.
*/
function normalizeOriginHost(value: string): string {
const trimmed = value.trim().replace(/\/+$/, "");
try {
return new URL(trimmed).host.toLowerCase();
} catch {
return trimmed.toLowerCase();
}
}

const STATIC_ORIGINS = (Deno.env.get("ALLOWED_ORIGINS") ?? "")
.split(",").map((s) => s.trim()).filter(Boolean);
const DOMAIN_CACHE_MS = 5 * 60 * 1000;
let domainCache: { hosts: Set<string>; fetchedAt: number } | null = null;

async function allowedHosts(): Promise<Set<string>> {
if (domainCache && Date.now() - domainCache.fetchedAt < DOMAIN_CACHE_MS) {
return domainCache.hosts;
}
const hosts = new Set<string>();
for (const o of STATIC_ORIGINS) hosts.add(normalizeOriginHost(o));
try {
const { data, error } = await supabaseAdmin
.from("site_domains").select("hostname").eq("is_active", true);
if (error) throw error;
for (const d of data ?? []) if (d.hostname) hosts.add(String(d.hostname).toLowerCase());
} catch (e) {
// If the lookup fails, fall back to whatever the last good cache had;
// failing closed here would lock every browser out of payments.
console.error("site_domains lookup failed, using cached/static origins:", e);
return domainCache?.hosts ?? new Set(STATIC_ORIGINS.map(normalizeOriginHost));
}
domainCache = { hosts, fetchedAt: Date.now() };
return hosts;
}

async function corsHeaders(req: Request): Promise<Record<string, string>> {
const h: Record<string, string> = {
"Access-Control-Allow-Headers": "Content-Type, Authorization, apikey",
"Access-Control-Allow-Methods": "POST, OPTIONS",
"Vary": "Origin",
};
const origin = req.headers.get("Origin");
if (!origin) return h; // server-to-server call: no CORS needed at all
let originHost = "";
try { originHost = new URL(origin).host; } catch { return h; }
if ((await allowedHosts()).has(originHost)) {
h["Access-Control-Allow-Origin"] = origin;
}
return h;
}
function json(body: unknown, status = 200, cors: Record<string, string> = {}) {
return new Response(JSON.stringify(body), {
status,
headers: { "Content-Type": "application/json", ...cors },
});
}
const VALID_METHODS = ["bkash", "nagad", "binance", "lightning", "usdt_bep20", "bank"];


Deno.serve(async (req) => {
const cors = await corsHeaders(req);
if (req.method === "OPTIONS") return new Response(null, { headers: cors });
if (req.method !== "POST") return json({ error: "Method not allowed" }, 405, cors);
const authHeader = req.headers.get("Authorization");
if (!authHeader) return json({ error: "Unauthorized" }, 401, cors);
// The caller client carries the user's JWT, so request_withdrawal() runs as
// that user and every check inside it (auth, balance, fee, row lock) applies.
const callerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
global: { headers: { Authorization: authHeader } },
});
const { data: { user }, error: userErr } = await callerClient.auth.getUser(authHeader.replace(/^Bearer\s+/i, ""));
if (userErr || !user) return json({ error: "Invalid session" }, 401, cors);
let body: { amount?: unknown; method?: unknown; destination?: unknown; request_key?: unknown };
try {
body = await req.json();
} catch {
return json({ error: "Invalid JSON body" }, 400, cors);
}
const amount = Number(body.amount);
const method = String(body.method ?? "").trim();
const destination = String(body.destination ?? "").trim();
// Optional idempotency key (0088). Anything that isn't a UUID is ignored.
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const requestKey = typeof body.request_key === "string" && UUID_RE.test(body.request_key)
? body.request_key
: null;
// Cheap client-side-mirroring checks. The authoritative versions all live
// in request_withdrawal(); these only exist to return a nicer error faster.
if (!Number.isFinite(amount) || amount < 5) {
return json({ error: "Minimum withdrawal is $5" }, 400, cors);
}
if (!VALID_METHODS.includes(method)) {
return json({ error: "Invalid withdrawal method" }, 400, cors);
}
if (!destination) {
return json({ error: "Destination account is required" }, 400, cors);
}
// A Lightning destination is a bolt11 invoice or a Lightning Address.
const LN_INVOICE = /^ln(bc|tb|bcrt)[0-9a-z]+$/i;
const LN_ADDRESS = /^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/;
if (method === "lightning" && !LN_INVOICE.test(destination) && !LN_ADDRESS.test(destination)) {
return json({
error: "That does not look like a Lightning invoice or a Lightning Address (you@wallet.com)",
}, 400, cors);
}
// ---- Single source of truth: the database decides ----
// Previously this function did its own balance maths against a different
// definition than request_withdrawal(), which let the same money be
// withdrawn twice. Now there is one code path.
const { data: withdrawal, error: rpcErr } = await callerClient
.rpc("request_withdrawal", requestKey
? { p_amount: amount, p_method: method, p_destination: destination, p_request_key: requestKey }
: { p_amount: amount, p_method: method, p_destination: destination });
// Same key seen before: the first request already created the withdrawal
// Answer success without doing anything again.
if (rpcErr?.message === "DUPLICATE_REQUEST") {
return json({ ok: true, duplicate: true, msg: "Already submitted / ইতিমধ্যে জমা দেওয়া হয়েছে" }, 200, cors);
}
if (rpcErr || !withdrawal) {
// Postgres RAISE messages here are user-facing and intentionally safe
// ("Insufficient balance. Available: $12.40").
return json({ error: rpcErr?.message ?? "Could not create withdrawal request" }, 400, cors);
}
const row = Array.isArray(withdrawal) ? withdrawal[0] : withdrawal;
const withdrawalId = row.id as string;
// Every withdrawal goes to the admin queue; nothing is paid out automatically.
// Withdraw fee (0115) is snapshotted on the row by request_withdrawal().
return json({
status: "pending",
withdrawalId,
amount: Number(row.amount_requested),
feePercent: Number(row.fee_percent ?? 0),
feeFixedUsd: Number(row.fee_fixed_usd ?? 0),
feeUsd: Number(row.fee_usd ?? 0),
receiveUsd: Number(row.amount_after_fee ?? row.amount_requested),
msg: "Request queued for admin approval.",
}, 200, cors);
});
