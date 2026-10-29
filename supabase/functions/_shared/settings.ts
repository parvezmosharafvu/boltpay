import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

export interface LndSettings {
  enabled: boolean;
  onchainFallback: boolean;
  minUsd: number;
  maxUsd: number;
  expirySec: number;
}

// Defaults mirror 0067 and are the SAFE values: a missing row means off.
export function parseLndSettings(rows: { key: string; value: unknown }[]): LndSettings {
  const m = new Map(rows.map((r) => [r.key, r.value]));
  const num = (k: string, d: number) => {
    const n = Number(m.get(k));
    return Number.isFinite(n) && n > 0 ? n : d;
  };
  const expiry = Math.round(num("lnd_invoice_expiry_sec", 3600));
  return {
    enabled: m.get("lnd_checkout_enabled") === true,
    onchainFallback: m.get("lnd_onchain_fallback") === true,
    minUsd: num("lnd_pay_min_usd", 10),
    maxUsd: num("lnd_pay_max_usd", 1000),
    expirySec: Math.min(Math.max(expiry, 300), 86400),
  };
}

export async function loadLndSettings(db: SupabaseClient): Promise<LndSettings> {
  const { data, error } = await db
    .from("app_settings")
    .select("key, value")
    .in("key", ["lnd_checkout_enabled", "lnd_onchain_fallback", "lnd_pay_min_usd", "lnd_pay_max_usd", "lnd_invoice_expiry_sec"]);
  if (error) throw new Error(`settings: ${error.message}`);
  return parseLndSettings(data ?? []);
}
