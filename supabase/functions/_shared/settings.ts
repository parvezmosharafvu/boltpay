import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

export interface LndSettings {
  enabled: boolean;
  onchainFallback: boolean;
  minUsd: number;
  maxUsd: number;
  expirySec: number;
  markupPercent: number;
  linkMarkupEnabled: boolean;
  linkMarkupMin: number;
  linkMarkupMax: number;
}

// Owner decision (pt297u): never below $10 entered, customer pays +10%.
export const MIN_USD_FLOOR = 10;
export const DEFAULT_MARKUP_PERCENT = 10;

// Defaults mirror 0067 and are the SAFE values: a missing row means off.
function markup(v: unknown): number {
  const n = Number(v);
  return v != null && Number.isFinite(n) && n >= 0 && n <= 100 ? n : DEFAULT_MARKUP_PERCENT;
}

function pct(v: unknown, d: number): number {
  const n = Number(v);
  return v != null && Number.isFinite(n) && n >= 0 && n <= 100 ? n : d;
}

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
    minUsd: Math.max(num("lnd_pay_min_usd", MIN_USD_FLOOR), MIN_USD_FLOOR),
    maxUsd: num("lnd_pay_max_usd", 1000),
    expirySec: Math.min(Math.max(expiry, 300), 86400),
    markupPercent: markup(m.get("lnd_customer_markup_percent")),
    // Per-link markup (0103). Flag defaults OFF: global markup only.
    linkMarkupEnabled: m.get("link_markup_enabled") === true,
    linkMarkupMin: pct(m.get("link_markup_min_percent"), 0),
    linkMarkupMax: pct(m.get("link_markup_max_percent"), 50),
  };
}

export async function loadLndSettings(db: SupabaseClient): Promise<LndSettings> {
  const { data, error } = await db
    .from("app_settings")
    .select("key, value")
    .in("key", ["lnd_checkout_enabled", "lnd_onchain_fallback", "lnd_pay_min_usd", "lnd_pay_max_usd", "lnd_invoice_expiry_sec", "lnd_customer_markup_percent", "link_markup_enabled", "link_markup_min_percent", "link_markup_max_percent"]);
  if (error) throw new Error(`settings: ${error.message}`);
  return parseLndSettings(data ?? []);
}
