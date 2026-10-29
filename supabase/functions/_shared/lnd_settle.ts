// Shared "LND says SETTLED/expired" handling for payment-status and
// lnd-watcher. Both paths end in the same idempotent SQL functions, so a
// payment is credited exactly once no matter who sees it first.
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { LndClient } from "./lnd.ts";

export interface OpenLndRow {
  id: string;
  user_id: string;
  lnd_r_hash: string;
  status: string;
  expires_at: string;
}

export type SyncOutcome = "settled" | "expired" | "open" | "unchanged";

export async function syncLndPayment(
  db: SupabaseClient,
  lnd: LndClient,
  row: OpenLndRow,
  now = Date.now(),
): Promise<SyncOutcome> {
  if (row.status !== "new" && row.status !== "pending") return "unchanged";
  const inv = await lnd.lookupInvoice(row.lnd_r_hash);
  if (inv.state === "SETTLED") {
    const { data, error } = await db.rpc("system_settle_lnd_payment", {
      p_r_hash: row.lnd_r_hash,
      p_amt_paid_msat: inv.amtPaidMsat.toString(),
    });
    if (error) throw new Error(`settle failed for ${row.id}: ${error.message}`);
    if (data === true) {
      // Same post-settle step as btcpay-webhook.
      const { error: qErr } = await db.rpc("system_queue_withdrawal", { p_user_id: row.user_id });
      if (qErr) console.error("Auto-queue failed for", row.user_id, qErr.message);
      return "settled";
    }
    return "unchanged";
  }
  // LND marks an invoice CANCELED; an OPEN invoice past expiry can no
  // longer be paid either (LND refuses HTLCs after expiry).
  if (inv.state === "CANCELED" || (inv.state === "OPEN" && new Date(row.expires_at).getTime() + 60_000 < now)) {
    const { data, error } = await db.rpc("system_expire_lnd_payment", { p_r_hash: row.lnd_r_hash });
    if (error) throw new Error(`expire failed for ${row.id}: ${error.message}`);
    return data === true ? "expired" : "unchanged";
  }
  return "open";
}
