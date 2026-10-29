// LND checkout: funnel events from the /pay/* pages (view, pay-click,
// paid-observed, btc-fallback) into payment_events. Anonymous by design;
// only accepts events for existing LND payments, caps rows per payment,
// and always answers 204 so the page never waits on analytics.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const EVENTS = new Set(["view", "pay-click", "paid-observed", "btc-fallback"]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_PER_PAYMENT = 50;
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const done = (status = 204) => new Response(null, { status, headers: CORS });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return done(200);
  if (req.method !== "POST") return done(405);
  let b: Record<string, unknown>;
  try {
    b = await req.json();
  } catch {
    return done(400);
  }
  const paymentId = String(b.paymentId ?? "");
  const event = String(b.event ?? "");
  if (!UUID.test(paymentId) || !EVENTS.has(event)) return done(400);
  const dev = String(b.deviceId ?? "");
  const deviceId = /^[A-Za-z0-9-]{8,64}$/.test(dev) ? dev : null;

  const { data: pay } = await db.from("payments").select("id").eq("id", paymentId).eq("backend", "lnd").maybeSingle();
  if (!pay) return done();
  const { count } = await db.from("payment_events").select("id", { count: "exact", head: true }).eq("payment_id", paymentId);
  if ((count ?? 0) >= MAX_PER_PAYMENT) return done();

  const { error } = await db.from("payment_events").insert({
    payment_id: paymentId,
    event,
    device_id: deviceId,
    ua: (req.headers.get("user-agent") ?? "").slice(0, 256) || null,
  });
  if (error) console.error("track-event:", error.message);
  return done();
});
