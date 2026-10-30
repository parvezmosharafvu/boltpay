// Shared "LND says SETTLED/expired" handling for payment-status and
// lnd-watcher. Both paths end in the same idempotent SQL functions, so a
// payment is credited exactly once no matter who sees it first.
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { LndClient } from "./lnd.ts";
import { notifyLndSettled } from "./alerts.ts";
import { isPaid, lookupAddress, type OnchainView } from "./onchain.ts";

export interface OpenLndRow {
  id: string;
  user_id: string;
  lnd_r_hash: string;
  status: string;
  expires_at: string;
  btc_address?: string | null;
  amount_sats?: number | null;
}

export type AddressLookup = (address: string) => Promise<OnchainView>;

export type SyncOutcome = "settled" | "expired" | "open" | "unchanged";

export async function syncLndPayment(
  db: SupabaseClient,
  lnd: LndClient,
  row: OpenLndRow,
  now = Date.now(),
  lookup: AddressLookup = (a) => lookupAddress(a),
): Promise<SyncOutcome> {
  const hasAddr = !!row.btc_address && Number(row.amount_sats) > 0;
  // An invoice that expired on Lightning can still be paid to its address.
  if (row.status === "expired" && hasAddr) {
    return (await settleOnchain(db, lookup, row)).outcome;
  }
  if (row.status !== "new" && row.status !== "pending") return "unchanged";
  const inv = await lnd.lookupInvoice(row.lnd_r_hash);
  if (inv.state === "SETTLED") {
    const { data, error } = await db.rpc("system_settle_lnd_payment", {
      p_r_hash: row.lnd_r_hash,
      p_amt_paid_msat: inv.amtPaidMsat.toString(),
    });
    if (error) throw new Error(`settle failed for ${row.id}: ${error.message}`);
    if (data === true) {
      // Post-settle: queue any automatic withdrawal.
      const { error: qErr } = await db.rpc("system_queue_withdrawal", { p_user_id: row.user_id });
      if (qErr) console.error("Auto-queue failed for", row.user_id, qErr.message);
      // Only the caller whose settle returned true gets here, so the
      // alert fires once even if status and watcher race.
      await notifyLndSettled(db, row.id);
      return "settled";
    }
    return "unchanged";
  }
  // Lightning not paid: check the on-chain fallback address.
  let seenOnchain = false;
  if (hasAddr) {
    const r = await settleOnchain(db, lookup, row);
    if (r.outcome === "settled") return "settled";
    seenOnchain = r.seen;
  }
  // LND marks an invoice CANCELED; an OPEN invoice past expiry can no
  // longer be paid either (LND refuses HTLCs after expiry).
  // Never expire while an on-chain payment is waiting for confirmation.
  if (seenOnchain) return "open";
  if (inv.state === "CANCELED" || (inv.state === "OPEN" && new Date(row.expires_at).getTime() + 60_000 < now)) {
    const { data, error } = await db.rpc("system_expire_lnd_payment", { p_r_hash: row.lnd_r_hash });
    if (error) throw new Error(`expire failed for ${row.id}: ${error.message}`);
    return data === true ? "expired" : "unchanged";
  }
  return "open";
}

async function settleOnchain(
  db: SupabaseClient,
  lookup: AddressLookup,
  row: OpenLndRow,
): Promise<{ outcome: SyncOutcome; seen: boolean }> {
  const v = await lookup(row.btc_address!);
  const seen = v.confirmedSats + v.mempoolSats > 0;
  if (!isPaid(v, Number(row.amount_sats))) {
    if (v.confirmedSats > 0) console.error("onchain underpaid:", row.id, v.confirmedSats, "<", row.amount_sats);
    return { outcome: "open", seen };
  }
  const { data, error } = await db.rpc("system_settle_onchain_payment", {
    p_id: row.id,
    p_txid: v.txid,
    p_received_sats: v.confirmedSats,
  });
  if (error) throw new Error(`onchain settle failed for ${row.id}: ${error.message}`);
  if (data !== true) return { outcome: "unchanged", seen };
  const { error: qErr } = await db.rpc("system_queue_withdrawal", { p_user_id: row.user_id });
  if (qErr) console.error("Auto-queue failed for", row.user_id, qErr.message);
  await notifyLndSettled(db, row.id);
  return { outcome: "settled", seen };
}
