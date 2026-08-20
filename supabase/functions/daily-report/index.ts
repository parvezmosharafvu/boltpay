import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

serve(async (req) => {
  // Optional: protect with a shared secret so only your cron trigger can call it
  const authHeader = req.headers.get("x-cron-secret");
  if (authHeader !== Deno.env.get("CRON_SECRET")) {
    return new Response("Unauthorized", { status: 401 });
  }

  // Compute "today" in UTC+6 (Bangladesh time), then convert to UTC range
  const now = new Date();
  const bdOffsetMs = 6 * 60 * 60 * 1000;
  const bdNow = new Date(now.getTime() + bdOffsetMs);
  const bdDateStr = bdNow.toISOString().slice(0, 10); // YYYY-MM-DD in BD "local" terms

  // Day boundaries in UTC (since BD is UTC+6, day starts at 18:00 UTC previous day)
  const dayStartUTC = new Date(`${bdDateStr}T00:00:00+06:00`);
  const dayEndUTC = new Date(`${bdDateStr}T23:59:59+06:00`);

  // Fetch settled payments for the day
  const { data: payments, error } = await supabase
    .from("payments")
    .select("amount_settled, user_id")
    .eq("status", "settled")
    .gte("settled_at", dayStartUTC.toISOString())
    .lte("settled_at", dayEndUTC.toISOString());

  if (error) {
    console.error("Fetch error:", error);
    return new Response("Fetch failed", { status: 500 });
  }

  const totalSettled = (payments || []).reduce(
    (sum, p) => sum + Number(p.amount_settled || 0),
    0
  );
  const paymentCount = (payments || []).length;

  // Fetch admin exchange rates to calculate profit
  const { data: rateSettings } = await supabase
    .from("app_settings")
    .select("value")
    .eq("key", "exchange_rates")
    .single();

  const buyRate = rateSettings?.value?.buy_rate ?? 1.0;
  const sellRate = rateSettings?.value?.sell_rate ?? 1.0;
  const adminProfit = totalSettled * (sellRate - buyRate);

  // Fetch withdrawals paid out today
  const { data: withdrawals } = await supabase
    .from("withdrawals")
    .select("amount_after_fee")
    .eq("status", "paid")
    .gte("processed_at", dayStartUTC.toISOString())
    .lte("processed_at", dayEndUTC.toISOString());

  const totalWithdrawn = (withdrawals || []).reduce(
    (sum, w) => sum + Number(w.amount_after_fee || 0),
    0
  );

  // Upsert into daily_stats — one row per day, no bloat
  const { error: upsertErr } = await supabase.from("daily_stats").upsert({
    stat_date: bdDateStr,
    total_settled: totalSettled,
    total_admin_profit: adminProfit,
    total_withdrawn: totalWithdrawn,
    payment_count: paymentCount,
    computed_at: new Date().toISOString(),
  });

  if (upsertErr) {
    console.error("Upsert error:", upsertErr);
    return new Response("Upsert failed", { status: 500 });
  }

  return new Response(
    JSON.stringify({ date: bdDateStr, totalSettled, adminProfit, paymentCount }),
    { status: 200, headers: { "Content-Type": "application/json" } }
  );
});