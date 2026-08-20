// supabase/functions/process-withdrawal/index.ts
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BTCPAY_URL = Deno.env.get("BTCPAY_URL")!;
const BTCPAY_API_KEY = Deno.env.get("BTCPAY_API_KEY")!;
const BTCPAY_STORE_ID = Deno.env.get("BTCPAY_STORE_ID")!;

const supabaseAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  // Verify the caller is a logged-in admin — using their own JWT, not service role
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return new Response("Missing auth", { status: 401 });

  const callerClient = createClient(SUPABASE_URL, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: userErr } = await callerClient.auth.getUser();
  if (userErr || !user) return new Response("Invalid session", { status: 401 });

  const { data: profile } = await supabaseAdmin
    .from("profiles").select("role").eq("id", user.id).single();
  if (profile?.role !== "admin") return new Response("Forbidden", { status: 403 });

  const { withdrawalId, action } = await req.json(); // action: 'approve' | 'reject'

  const { data: withdrawal, error: fetchErr } = await supabaseAdmin
    .from("withdrawals").select("*").eq("id", withdrawalId).single();
  if (fetchErr || !withdrawal) return new Response("Withdrawal not found", { status: 404 });

  if (withdrawal.status !== "pending" && withdrawal.status !== "approved") {
    return new Response("Withdrawal already processed", { status: 409 });
  }

  if (action === "reject") {
    await supabaseAdmin.from("withdrawals").update({ status: "rejected", processed_at: new Date().toISOString() }).eq("id", withdrawalId);
    return new Response(JSON.stringify({ status: "rejected" }), { status: 200 });
  }

  if (action !== "approve") return new Response("Invalid action", { status: 400 });

  // Create the actual BTCPay payout — this is the money-moving step
  const payoutRes = await fetch(`${BTCPAY_URL}/api/v1/stores/${BTCPAY_STORE_ID}/payouts`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": `token ${BTCPAY_API_KEY}` },
    body: JSON.stringify({
      destination: withdrawal.destination,
      amount: withdrawal.amount_after_fee,
      paymentMethod: withdrawal.method === "binance" ? "BTC-LightningNetwork" : "BTC-LightningNetwork",
    }),
  });

  if (!payoutRes.ok) {
    const errText = await payoutRes.text();
    console.error("BTCPay payout failed:", errText);
    return new Response(JSON.stringify({ error: "Payout failed", detail: errText }), { status: 502 });
  }

  const payoutData = await payoutRes.json();

  const { error: updateErr } = await supabaseAdmin
    .from("withdrawals")
    .update({ status: "paid", processed_at: new Date().toISOString(), admin_note: `BTCPay payout: ${payoutData.id}` })
    .eq("id", withdrawalId);

  if (updateErr) {
    console.error("Status update failed after payout sent:", updateErr);
    return new Response(JSON.stringify({ warning: "Payout sent but status update failed — check manually", payoutId: payoutData.id }), { status: 500 });
  }

  return new Response(JSON.stringify({ status: "paid", payoutId: payoutData.id }), { status: 200 });
});