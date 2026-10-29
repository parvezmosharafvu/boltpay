// BTC/USD from two independent public sources. Refuses to price when they
// disagree by more than 2%, so one bad feed cannot under-charge a payer.

type Fetch = typeof fetch;
let cache: { rate: number; at: number } | null = null;
const TTL_MS = 60_000;

async function kraken(f: Fetch): Promise<number> {
  const r = await f("https://api.kraken.com/0/public/Ticker?pair=XBTUSD", { signal: AbortSignal.timeout(5000) });
  const j = await r.json();
  const k = Object.keys(j?.result ?? {})[0];
  return Number(j?.result?.[k]?.c?.[0]);
}

async function coinbase(f: Fetch): Promise<number> {
  const r = await f("https://api.coinbase.com/v2/prices/BTC-USD/spot", { signal: AbortSignal.timeout(5000) });
  const j = await r.json();
  return Number(j?.data?.amount);
}

export function combineRates(a: number, b: number, maxSpread = 0.02): number {
  const ok = (x: number) => Number.isFinite(x) && x > 1000 && x < 10_000_000;
  if (!ok(a) || !ok(b)) throw new Error("rate source unavailable");
  if (Math.abs(a - b) / Math.min(a, b) > maxSpread) throw new Error("rate sources disagree");
  return Math.round(((a + b) / 2) * 100) / 100;
}

export async function btcUsdRate(f: Fetch = fetch, now = Date.now()): Promise<number> {
  if (cache && now - cache.at < TTL_MS) return cache.rate;
  const [a, b] = await Promise.all([kraken(f).catch(() => NaN), coinbase(f).catch(() => NaN)]);
  const rate = combineRates(a, b);
  cache = { rate, at: now };
  return rate;
}

export function _resetRateCache() {
  cache = null;
}
