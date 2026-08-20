import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { crypto } from "https://deno.land/std@0.224.0/crypto/mod.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BTCPAY_WEBHOOK_SECRET = Deno.env.get("BTCPAY_WEBHOOK_SECRET")!;
const BTCPAY_URL = Deno.env.get("BTCPAY_URL")!;
const BTCPAY_API_KEY = Deno.env.get("BTCPAY_API_KEY")!;
const BTCPAY_STORE_ID = Deno.env.get("BTCPAY_STORE_ID")!;

const supabaseAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

async function verifySignature(rawBody: string, signatureHeader: string | null): Promise<boolean> {
  if (!signatureHeader) return false;
  const sigParts = signatureHeader.split("=");
  if (sigParts.length !== 2 || sigParts[0] !== "sha256") return false;
  const providedSig = sigParts[1];

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(BTCPAY_WEBHOOK_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signatureBuffer = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(rawBody));
  const computedSig = Array.from(new Uint8Array(signatureBuffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

  if (computedSig.length !== providedSig.length) return false;
  let diff = 0;
  for (let i = 0; i < computedSig.length; i++) {
    diff |= computedSig.charCodeAt(i) ^ providedSig.charCodeAt(i);
  }
  return diff === 0;
}

async function verifyAdminCaller(req: Request): Promise<{ ok: boolean; userId?: string }> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return { ok: false };

  const callerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error } = await callerClient.auth.getUser();
  if (error || !user) return { ok: false };

  const { data: profile } = await supabaseAdmin
    .from("profiles").select("role").eq("id", user.id).single();
  if (profile?.role !== "admin") return { ok: false };

  return { ok: true, userId: user.id };
}

serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const url = new URL(req.url);

  // ==========================================
  // ROUTE: /process-withdrawal  (admin-only)
  // ==========================================
  if (url.pathname.endsWith("/process-withdrawal")) {
    const auth = await verifyAdminCaller(req);
    if (!auth.ok) {
      return new Response("Unauthorized — admin session required", { status: 401 });
    }

    try {
      const payload = await req.json();
      const { withdrawalId, action } = payload;

      const { data: withdrawal, error: fetchErr } = await supabaseAdmin
        .from("withdrawals")
        .select("*")
        .eq("id", withdrawalId)
        .single();

      if (fetchErr || !withdrawal) {
        return new Response("Withdrawal not found", { status: 404 });
      }

      if (action === "reject") {
        if (withdrawal.status === "paid") {
          return new Response("Already paid — cannot reject", { status: 409 });
        }
        await supabaseAdmin.from("withdrawals").update({
          status: "rejected",
          processed_at: new Date().toISOString(),
        }).eq("id", withdrawalId);
        return new Response(JSON.stringify({ status: "rejected" }), {
          status: 200, headers: { "Content-Type": "application/json" },
        });
      }

      if (action === "mark_paid_manual") {
        if (withdrawal.status !== "approved") {
          return new Response("Only approved withdrawals can be marked paid manually", { status: 409 });
        }
        if (withdrawal.method === "binance") {
          return new Response("Binance withdrawals must use the automated payout, not manual mark", { status: 400 });
        }
        await supabaseAdmin.from("withdrawals").update({
          status: "paid",
          processed_at: new Date().toISOString(),
          admin_note: "Manually paid via " + withdrawal.method,
        }).eq("id", withdrawalId);
        return new Response(JSON.stringify({ status: "paid" }), {
          status: 200, headers: { "Content-Type": "application/json" },
        });
      }

      if (action === "approve") {
        if (withdrawal.status !== "pending" && withdrawal.status !== "approved") {
          return new Response("Withdrawal already processed", { status: 409 });
        }
        if (withdrawal.method !== "binance") {
          return new Response("Only binance withdrawals use the automated payout route", { status: 400 });
        }

        const payoutRes = await fetch(`${BTCPAY_URL}/api/v1/stores/${BTCPAY_STORE_ID}/payouts`, {
          method: "POST",
          headers: { "Content-Type": "application/json", "Authorization": `token ${BTCPAY_API_KEY}` },
          body: JSON.stringify({
            destination: withdrawal.destination,
            amount: withdrawal.amount_after_fee,
            paymentMethod: "BTC-LN",
          }),
        });

        if (!payoutRes.ok) {
          const errText = await payoutRes.text();
          console.error("BTCPay payout failed:", errText);
          return new Response(JSON.stringify({ error: "Payout failed", detail: errText }), { status: 502 });
        }

        const payoutData = await payoutRes.json();

        const { error: updateErr } = await supabaseAdmin.from("withdrawals").update({
          status: "paid",
          processed_at: new Date().toISOString(),
          admin_note: `BTCPay payout: ${payoutData.id}`,
        }).eq("id", withdrawalId);

        if (updateErr) {
          console.error("Status update failed after payout sent:", updateErr);
          return new Response(JSON.stringify({ warning: "Payout sent but status update failed — check manually", payoutId: payoutData.id }), { status: 500 });
        }

        return new Response(JSON.stringify({ status: "paid", payoutId: payoutData.id }), {
          status: 200, headers: { "Content-Type": "application/json" },
        });
      }

      return new Response("Invalid action", { status: 400 });
    } catch (e) {
      console.error("process-withdrawal error:", e);
      return new Response("Error processing withdrawal", { status: 500 });
    }
  }

  // ==========================================
  // ROUTE: BTCPay Webhook (default — signature protected)
  // ==========================================
  const rawBody = await req.text();
  const signature = req.headers.get("btcpay-sig");

  const isValid = await verifySignature(rawBody, signature);
  if (!isValid) {
    console.error("Invalid BTCPay webhook signature");
    return new Response("Invalid signature", { status: 401 });
  }

  const event = JSON.parse(rawBody);
  const invoiceId: string = event.invoiceId;
  const eventType: string = event.type;

  const { data: payment, error: fetchErr } = await supabaseAdmin
    .from("payments")
    .select("id, user_id, amount_requested, status")
    .eq("btcpay_invoice_id", invoiceId)
    .single();

  if (fetchErr || !payment) {
    console.error("Payment not found for invoice:", invoiceId);
    return new Response("Payment not found", { status: 404 });
  }

  if (payment.status === "settled" && eventType === "InvoiceSettled") {
    return new Response("Already processed", { status: 200 });
  }

  let newStatus: string | null = null;
  if (eventType === "InvoiceSettled") newStatus = "settled";
  else if (eventType === "InvoiceExpired") newStatus = "expired";
  else if (eventType === "InvoiceProcessing" || eventType === "InvoiceReceivedPayment") newStatus = "pending";
  else if (eventType === "InvoiceInvalid") newStatus = "invalid";

  if (!newStatus) {
    return new Response("Event ignored", { status: 200 });
  }

  const updatePayload: Record<string, unknown> = { status: newStatus };
  if (newStatus === "settled") {
    updatePayload.settled_at = new Date().toISOString();
    updatePayload.amount_settled = event.amount ?? payment.amount_requested;
  }

  const { error: updateErr } = await supabaseAdmin
    .from("payments")
    .update(updatePayload)
    .eq("id", payment.id);

  if (updateErr) {
    console.error("Failed to update payment:", updateErr);
    return new Response("Update failed", { status: 500 });
  }

  if (newStatus === "settled") {
    await maybeQueueAutoWithdrawal(payment.user_id);
  }

  return new Response("OK", { status: 200 });
});

// ---- Auto-withdrawal logic (threshold-based hybrid, with global on/off) ----
async function maybeQueueAutoWithdrawal(userId: string) {
  const { data: enabledRow } = await supabaseAdmin
    .from("app_settings")
    .select("value")
    .eq("key", "auto_withdraw_enabled")
    .single();

  if (enabledRow?.value === false) {
    console.log("Auto-withdraw is globally disabled — skipping");
    return;
  }

  const { data: settingsRow } = await supabaseAdmin
    .from("app_settings")
    .select("value")
    .eq("key", "auto_withdraw_threshold")
    .single();

  const threshold = settingsRow?.value?.amount ?? 50;

  const { data: profile } = await supabaseAdmin
    .from("profiles")
    .select("withdrawal_fee_percent")
    .eq("id", userId)
    .single();

  const feePercent = profile?.withdrawal_fee_percent ?? 3.0;

  const { data: settledPayments } = await supabaseAdmin
    .from("payments")
    .select("amount_settled")
    .eq("user_id", userId)
    .eq("status", "settled")
    .is("withdrawal_id", null);

  const totalAvailable = (settledPayments || []).reduce(
    (sum, p) => sum + Number(p.amount_settled || 0),
    0
  );

  if (totalAvailable <= 0) return;

  const amountAfterFee = totalAvailable * (1 - feePercent / 100);
  const autoApprove = totalAvailable < threshold;

  await supabaseAdmin.from("withdrawals").insert({
    user_id: userId,
    amount_requested: totalAvailable,
    fee_percent: feePercent,
    amount_after_fee: amountAfterFee,
    status: autoApprove ? "approved" : "pending",
    method: "pending_selection",
  });
}
