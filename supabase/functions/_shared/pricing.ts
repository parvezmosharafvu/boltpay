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
 * Buyer markup % for one invoice (0105): the link's own "extra fee",
 * fixed at creation, clamped to the admin range; otherwise 0. No profile
 * or global fallback. `linkMarkupEnabled` is kept for compatibility but no
 * longer gates the link's own fee.
 */
export function resolveMarkup(
  link: { link_cost_percent?: unknown; profile_cost_percent?: unknown },
  s: MarkupInputs,
): number {
  const lo = Math.max(0, s.linkMarkupMin), hi = Math.max(lo, s.linkMarkupMax);
  const v = link.link_cost_percent;
  const l = v == null || v === "" ? NaN : Number(v);
  if (!Number.isFinite(l) || l <= 0) return 0;
  return Math.min(Math.max(l, lo), hi);
}
