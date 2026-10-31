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

export type FeeMode = "creator" | "buyer" | "split";

/** Buyer/creator share of the conversion fee % for a mode (0107). */
export function feeShares(mode: unknown, feePercent: unknown): { mode: FeeMode; buyer: number; creator: number } {
  const f = clampCostPercent(feePercent);
  const m: FeeMode = mode === "creator" || mode === "split" ? mode : "buyer"; // 0117: default buyer
  if (m === "buyer") return { mode: m, buyer: f, creator: 0 };
  if (m === "split") {
    // Integer thousandths so it matches SQL round(f / 2, 3) (half up).
    const fm = Math.round(f * 1000), bm = Math.round(fm / 2);
    return { mode: m, buyer: bm / 1000, creator: (fm - bm) / 1000 };
  }
  return { mode: m, buyer: 0, creator: f };
}

/**
 * Buyer total for a checkout (0107). G = base + link extra fee (cents);
 * buyer fee = round(G * buyer% / 100); total = G + buyer fee.
 */
export function quote(amountUsd: number, linkMarkup: unknown, mode: unknown, feePercent: unknown) {
  const s = feeShares(mode, feePercent);
  const gross = chargedAmount(amountUsd, linkMarkup);
  const buyerFeeUsd = roundCents(gross * s.buyer / 100);
  const total = roundCents(gross + buyerFeeUsd);
  const creatorFeeUsd = roundCents(gross * s.creator / 100);
  return { ...s, gross, buyerFeeUsd, total, creatorFeeUsd, creatorNet: roundCents(gross - creatorFeeUsd) };
}
