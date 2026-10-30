// LND checkout: status of one payment, polled by the invoice page every 3s.
//
// GET ?id=<uuid> -> { data: { status, paidAt, expiresAt, amountUSD,
//                             amountSats, bolt11, btcAddress } }
//
// Only LND rows are served. While a row is still open it asks LND directly
// and settles through the same idempotent SQL function as lnd-watcher, so a
// payer is never stuck waiting for the cron. Works even when the global
// flag is off, so invoices already issued can still complete.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { LndClient, lndConfig } from "../_shared/lnd.ts";
import { syncLndPayment } from "../_shared/lnd_settle.ts";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...CORS },
  });
}
const COLS = "id, user_id, status, lnd_r_hash, expires_at, paid_at, amount_requested, amount_sats, bolt11, btc_address";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "GET") return json({ error: { message: "Method not allowed" } }, 405);
  const id = new URL(req.url).searchParams.get("id") ?? "";
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) {
    return json({ error: { message: "Invalid payment id" } }, 400);
  }

  const load = () => db.from("payments").select(COLS).eq("id", id).eq("backend", "lnd").maybeSingle();
  let { data: row, error } = await load();
  if (error) return json({ error: { message: "Temporarily unavailable" } }, 503);
  if (!row) return json({ error: { message: "Payment not found" } }, 404);

  if (row.status === "new" || row.status === "pending" || (row.status === "expired" && row.btc_address)) {
    const cfg = await lndConfig(db);
    if (cfg) {
      try {
        const out = await syncLndPayment(db, new LndClient(cfg, fetch), row);
        if (out === "settled" || out === "expired") ({ data: row } = await load());
      } catch (e) {
        // Fall through with the stored status; the watcher will retry.
        console.error("sync:", (e as Error).message);
      }
    }
  }
  if (!row) return json({ error: { message: "Payment not found" } }, 404);

  const status = row.status === "settled" ? "paid" : row.status === "new" ? "pending" : row.status;
  return json({
    data: {
      status,
      paidAt: row.paid_at,
      expiresAt: row.expires_at,
      amountUSD: Number(row.amount_requested),
      amountSats: row.amount_sats,
      bolt11: row.status === "new" || row.status === "pending" ? row.bolt11 : null,
      btcAddress: row.status === "new" || row.status === "pending" ? row.btc_address : null,
      // BIP21 amount for the on-chain fallback page (same locked sats).
      amountBtc: row.amount_sats ? (Number(row.amount_sats) / 1e8).toFixed(8) : null,
    },
  });
});
