// Checkout markup maths.

export function clampCostPercent(raw: unknown): number {
  const n = Number(raw ?? 0);
  return Number.isFinite(n) ? Math.min(Math.max(n, 0), 1000) : 0;
}

export function roundCents(n: number): number {
  return Math.round(n * 100) / 100;
}

export function chargedAmount(amountUsd: number, costPercent: unknown): number {
  return roundCents(amountUsd * (1 + clampCostPercent(costPercent) / 100));
}

/** USD → whole sats, rounded up so the merchant is never short. */
export function usdToSats(usd: number, btcUsd: number): number {
  if (!(usd > 0) || !(btcUsd > 0)) throw new Error("invalid amount or rate");
  return Math.ceil((usd / btcUsd) * 1e8);
}

export function parseUsd(v: unknown): number | null {
  const n = roundCents(Number(v));
  return Number.isFinite(n) ? n : null;
}

export function withinLimits(amount: number, min: number, max: number): boolean {
  return amount >= min && amount <= max;
}

export interface MarkupInputs {
  linkMarkupEnabled: boolean;
  linkMarkupMin: number;
  linkMarkupMax: number;
}

/**
 * Buyer markup % for one invoice. Since 0104 there is no global buyer
 * markup (the old 2.5% is now the creator-side conversion fee), so every
 * fallback is 0. Flag ON: link % -> profile % (when > 0) -> 0, clamped
 * server-side to the admin range.
 */
export function resolveMarkup(
  link: { link_cost_percent?: unknown; profile_cost_percent?: unknown },
  s: MarkupInputs,
): number {
  if (!s.linkMarkupEnabled) return 0;
  const lo = Math.max(0, s.linkMarkupMin), hi = Math.max(lo, s.linkMarkupMax);
  const clamp = (n: number) => Math.min(Math.max(n, lo), hi);
  const num = (v: unknown) => (v == null || v === "" ? NaN : Number(v));
  const l = num(link.link_cost_percent);
  if (Number.isFinite(l)) return clamp(l);
  const p = num(link.profile_cost_percent);
  if (Number.isFinite(p) && p > 0) return clamp(p);
  return 0;
}
