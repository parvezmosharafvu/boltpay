// Same markup maths as create-invoice (kept in sync deliberately; the
// BTCPay function is not refactored so its behaviour cannot change).

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
