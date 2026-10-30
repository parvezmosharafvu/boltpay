// On-chain fallback: watch the per-invoice LND address through a public
// block explorer (mempool.space Esplora API). Read-only; LND is only used
// to create the address (newAddress). No wallet or channel calls.
//
// Rule: an invoice is paid on-chain when CONFIRMED outputs to its address
// add up to at least amount_sats minus a 0.5% tolerance (wallet rounding of
// the BIP21 amount). Less than that is never credited automatically.

export const ONCHAIN_TOLERANCE = 0.005;
export const ONCHAIN_MIN_CONF = 1;

export interface EsploraTx {
  txid: string;
  status?: { confirmed?: boolean; block_height?: number };
  vout?: { scriptpubkey_address?: string; value?: number }[];
}

export interface OnchainView {
  confirmedSats: number;
  mempoolSats: number;
  txid: string | null;
}

export function minAcceptSats(amountSats: number): number {
  return amountSats - Math.floor(amountSats * ONCHAIN_TOLERANCE);
}

/** Sum what the address received, split by confirmed / still in mempool. */
export function summarize(txs: EsploraTx[], address: string): OnchainView {
  let confirmedSats = 0, mempoolSats = 0, txid: string | null = null;
  for (const tx of txs) {
    let got = 0;
    for (const o of tx.vout ?? []) if (o.scriptpubkey_address === address) got += Number(o.value ?? 0);
    if (got <= 0) continue;
    if (tx.status?.confirmed) {
      confirmedSats += got;
      txid ??= tx.txid;
    } else mempoolSats += got;
  }
  return { confirmedSats, mempoolSats, txid };
}

export function isPaid(v: OnchainView, amountSats: number): boolean {
  return amountSats > 0 && v.confirmedSats >= minAcceptSats(amountSats) && v.txid !== null;
}

export async function lookupAddress(
  address: string,
  fetchFn: typeof fetch = fetch,
  base = Deno.env.get("ONCHAIN_EXPLORER_URL") ?? "https://mempool.space/api",
): Promise<OnchainView> {
  if (!/^(bc1|tb1|bcrt1)[a-z0-9]{20,90}$/.test(address)) throw new Error("bad address");
  const res = await fetchFn(`${base}/address/${address}/txs`, { signal: AbortSignal.timeout(8000) });
  if (!res.ok) throw new Error(`explorer ${res.status}`);
  const txs = await res.json();
  if (!Array.isArray(txs)) throw new Error("explorer shape");
  return summarize(txs as EsploraTx[], address);
}
