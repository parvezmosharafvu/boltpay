import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BTCPAY_URL = Deno.env.get("BTCPAY_URL")!;
const BTCPAY_API_KEY = Deno.env.get("BTCPAY_API_KEY")!;
const BTCPAY_STORE_ID = Deno.env.get("BTCPAY_STORE_ID")!;

const supabaseAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405, headers: CORS_HEADERS });
  }

  let body: { slug?: string; amount?: number };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const slug = (body.slug || "").trim();
  const amount = Number(body.amount);

  if (!slug) return json({ error: "Missing slug" }, 400);
  if (!amount || amount < 1 || amount > 5000) {
    return json({ error: "Amount must be between $1 and $5000" }, 400);
  }

  // Look up the payment link — must exist and be active
  const { data: link, error: linkErr } = await supabaseAdmin
    .from("payment_links")
    .select("id, user_id, slug, display_name, is_active")
    .eq("slug", slug)
    .single();

  if (linkErr || !link) return json({ error: "Payment link not found" }, 404);
  if (!link.is_active) return json({ error: "This payment link is no longer active" }, 410);

  // Create the BTCPay invoice
  const expirationMinutes = 60;
  let btcpayInvoice: any;
  try {
    const res = await fetch(`${BTCPAY_URL}/api/v1/stores/${BTCPAY_STORE_ID}/invoices`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `token ${BTCPAY_API_KEY}`,
      },
      body: JSON.stringify({
        amount: amount.toFixed(2),
        currency: "USD",
        checkout: {
          expirationMinutes,
          paymentMethods: ["BTC-LightningNetwork"],
          defaultPaymentMethod: "BTC-LightningNetwork",
        },
      }),
    });

    if (!res.ok) {
      const errText = await res.text();
      console.error("BTCPay invoice creation failed:", errText);
      return json({ error: "Could not create invoice", detail: errText }, 502);
    }
    btcpayInvoice = await res.json();
  } catch (e) {
    console.error("BTCPay request error:", e);
    return json({ error: "Payment provider unreachable" }, 502);
  }

  // Fetch the Lightning payment method to get the actual bolt11 payment request
  let payCode = "";
  try {
    const pmRes = await fetch(
      `${BTCPAY_URL}/api/v1/stores/${BTCPAY_STORE_ID}/invoices/${btcpayInvoice.id}/payment-methods`,
      { headers: { "Authorization": `token ${BTCPAY_API_KEY}` } }
    );
    if (pmRes.ok) {
      const methods = await pmRes.json();
      const ln = methods.find((m: any) => m.paymentMethod === "BTC-LightningNetwork");
      payCode = ln?.destination || "";
    }
  } catch (e) {
    console.error("Failed to fetch payment methods:", e);
  }

  const expiresAt = new Date(Date.now() + expirationMinutes * 60 * 1000).toISOString();

  // Record the payment in our own database
  const { data: payment, error: insertErr } = await supabaseAdmin
    .from("payments")
    .insert({
      payment_link_id: link.id,
      user_id: link.user_id,
      btcpay_invoice_id: btcpayInvoice.id,
      method: "lightning",
      amount_requested: amount,
      status: "new",
      expires_at: expiresAt,
    })
    .select("id")
    .single();

  if (insertErr || !payment) {
    console.error("Failed to record payment:", insertErr);
    return json({ error: "Could not record payment" }, 500);
  }

  return json({
    paymentId: payment.id,
    payCode,
    payUrl: payCode ? `lightning:${payCode}` : btcpayInvoice.checkoutLink,
    amountRequested: amount,
    expiresAt,
  });
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

