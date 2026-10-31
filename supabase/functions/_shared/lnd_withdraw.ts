// LND REST client for the owner-only node withdrawal feature.
//
// Kept separate from lnd.ts on purpose: checkout only ever holds the
// invoice macaroon, and this module is the only place that holds spend rights.
//
// Secrets (Edge Function env, or Supabase Vault 'lnd_rest_url' /
// 'lnd_withdraw_macaroon' via the service-role-only RPC
// system_lnd_withdraw_config from migration 0111):
//   LND_REST_URL            https base URL of the LND REST proxy
//   LND_WITHDRAW_MACAROON   hex, URI-scoped macaroon (never admin.macaroon),
//                           baked with exactly WITHDRAW_MACAROON_URIS below:
//     lncli bakemacaroon --root_key_id 4242 <each uri:... below>
//   CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET  optional Cloudflare Access
//
// No channel, peer, macaroon or stop RPCs exist here, and call() refuses any
// path outside ALLOWED_PATHS. Secrets are never logged or put in errors.

export const WITHDRAW_MACAROON_URIS = [
  "uri:/lnrpc.Lightning/GetInfo",
  "uri:/lnrpc.Lightning/WalletBalance",
  "uri:/lnrpc.Lightning/ChannelBalance",
  "uri:/lnrpc.Lightning/EstimateFee",
  "uri:/lnrpc.Lightning/SendCoins",
  "uri:/lnrpc.Lightning/DecodePayReq",
  "uri:/lnrpc.Lightning/SendPaymentSync",
] as const;

// REST paths for the URIs above, and nothing else.
const ALLOWED_PATHS: ReadonlyArray<[string, RegExp]> = [
  ["GET", /^\/v1\/getinfo$/],
  ["GET", /^\/v1\/balance\/blockchain$/],
  ["GET", /^\/v1\/balance\/channels$/],
  ["GET", /^\/v1\/transactions\/fee\?/],
  ["POST", /^\/v1\/transactions$/],
  ["GET", /^\/v1\/payreq\/[0-9a-z]+$/],
  ["POST", /^\/v1\/channels\/transactions$/],
];

export interface WithdrawConfig {
  baseUrl: string;
  macaroonHex: string;
  cfAccessId?: string;
  cfAccessSecret?: string;
  timeoutMs?: number;
}

export class WithdrawError extends Error {
  constructor(message: string, public status?: number) {
    super(message);
  }
}

type Getter = (k: string) => string | undefined;
const envGet: Getter = (k) => Deno.env.get(k);

export function withdrawConfigFromEnv(get: Getter = envGet): WithdrawConfig | null {
  const baseUrl = (get("LND_REST_URL") ?? "").trim().replace(/\/+$/, "");
  const macaroonHex = (get("LND_WITHDRAW_MACAROON") ?? "").trim();
  if (!baseUrl || !macaroonHex) return null;
  if (!/^https:\/\//.test(baseUrl)) return null;
  if (!/^[0-9a-fA-F]+$/.test(macaroonHex)) return null;
  return {
    baseUrl,
    macaroonHex,
    cfAccessId: get("CF_ACCESS_CLIENT_ID") || undefined,
    cfAccessSecret: get("CF_ACCESS_CLIENT_SECRET") || undefined,
  };
}

type RpcClient = { rpc: (fn: string, args?: Record<string, unknown>) => PromiseLike<{ data: unknown; error: unknown }> };

/** Env first, then Vault. Not cached: this is a rare, owner-only path. */
export async function withdrawConfig(db: RpcClient, get: Getter = envGet): Promise<WithdrawConfig | null> {
  const env = withdrawConfigFromEnv(get);
  if (env) return env;
  try {
    const { data, error } = await db.rpc("system_lnd_withdraw_config");
    if (error) {
      console.error("lnd withdraw config: vault rpc failed");
      return null;
    }
    const row = (Array.isArray(data) ? data[0] : data) as { rest_url?: string; macaroon?: string } | null;
    if (!row) return null;
    return withdrawConfigFromEnv((k) =>
      k === "LND_REST_URL" ? row.rest_url ?? undefined
      : k === "LND_WITHDRAW_MACAROON" ? row.macaroon ?? undefined
      : get(k)
    );
  } catch {
    console.error("lnd withdraw config: vault rpc threw");
    return null;
  }
}

// ── validation ───────────────────────────────────────────────

/** Mainnet address shape check (bech32/bech32m or base58 P2PKH/P2SH). LND does the real check. */
export function isMainnetAddress(a: string): boolean {
  const s = a.trim();
  if (/^bc1[02-9ac-hj-np-z]{11,71}$/.test(s)) return true;
  if (/^BC1[02-9AC-HJ-NP-Z]{11,71}$/.test(s)) return true;
  return /^[13][1-9A-HJ-NP-Za-km-z]{25,34}$/.test(s);
}

/** Mainnet BOLT11 shape check. */
export function normalizeInvoice(inv: string): string | null {
  const s = inv.trim().replace(/^lightning:/i, "").toLowerCase();
  return /^lnbc[0-9a-z]{20,1900}$/.test(s) ? s : null;
}

function posInt(n: number, what: string): string {
  if (!Number.isSafeInteger(n) || n <= 0) throw new WithdrawError(`bad ${what}`);
  return String(n);
}

// ── client ───────────────────────────────────────────────────

export interface Balances {
  onchainConfirmedSat: number;
  onchainUnconfirmedSat: number;
  lightningLocalSat: number;
}

export interface DecodedInvoice {
  destination: string;
  paymentHash: string;
  amountSat: number; // 0 = amountless
  description: string;
  expiresAt: number; // unix seconds
}

export interface SendCoinsArgs {
  address: string;
  satPerVbyte: number;
  amountSat?: number;
  sendAll?: boolean;
}

export interface PayResult {
  paymentHashHex: string;
  feeSat: number;
}

const toNum = (v: unknown) => Number(v ?? 0) || 0;

function b64ToHex(b64: string): string {
  const bin = atob(String(b64).replace(/-/g, "+").replace(/_/g, "/"));
  let out = "";
  for (let i = 0; i < bin.length; i++) out += bin.charCodeAt(i).toString(16).padStart(2, "0");
  return out;
}

export class LndWithdrawClient {
  constructor(private cfg: WithdrawConfig, private fetchFn: typeof fetch = fetch) {}

  private async call(method: "GET" | "POST", path: string, body?: unknown): Promise<any> {
    if (!ALLOWED_PATHS.some(([m, re]) => m === method && re.test(path))) {
      throw new WithdrawError(`path not allowed: ${method} ${path.split("?")[0]}`);
    }
    const headers: Record<string, string> = { "Grpc-Metadata-macaroon": this.cfg.macaroonHex };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (this.cfg.cfAccessId && this.cfg.cfAccessSecret) {
      headers["CF-Access-Client-Id"] = this.cfg.cfAccessId;
      headers["CF-Access-Client-Secret"] = this.cfg.cfAccessSecret;
    }
    let res: Response;
    try {
      res = await this.fetchFn(`${this.cfg.baseUrl}${path}`, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(this.cfg.timeoutMs ?? 30_000),
      });
    } catch (e) {
      throw new WithdrawError(`LND unreachable: ${(e as Error).name}`);
    }
    const text = await res.text();
    const route = path.split("?")[0].replace(/^\/v1\/payreq\/.*/, "/v1/payreq/…");
    if (!res.ok) throw new WithdrawError(`LND ${method} ${route} failed: ${res.status} ${text.slice(0, 120)}`, res.status);
    try {
      return JSON.parse(text);
    } catch {
      throw new WithdrawError("LND returned non-JSON");
    }
  }

  async balances(): Promise<Balances> {
    const [w, c] = await Promise.all([
      this.call("GET", "/v1/balance/blockchain"),
      this.call("GET", "/v1/balance/channels"),
    ]);
    return {
      onchainConfirmedSat: toNum(w.confirmed_balance),
      onchainUnconfirmedSat: toNum(w.unconfirmed_balance),
      lightningLocalSat: toNum(c.local_balance?.sat ?? c.balance),
    };
  }

  /** Mainnet and synced, so we never send on a lagging or wrong-chain node. */
  async assertReady(): Promise<void> {
    const i = await this.call("GET", "/v1/getinfo");
    const chain = (i.chains ?? [])[0] ?? {};
    if (chain.network && chain.network !== "mainnet") throw new WithdrawError("node is not on mainnet");
    if (!i.synced_to_chain) throw new WithdrawError("node is not synced to chain");
  }

  async estimateFee(address: string, amountSat: number, targetConf = 6): Promise<{ feeSat: number; satPerVbyte: number }> {
    if (!isMainnetAddress(address)) throw new WithdrawError("bad address");
    const q = `AddrToAmount[${encodeURIComponent(address.trim())}]=${posInt(amountSat, "amount")}&target_conf=${posInt(targetConf, "target")}`;
    const r = await this.call("GET", `/v1/transactions/fee?${q}`);
    return { feeSat: toNum(r.fee_sat), satPerVbyte: toNum(r.sat_per_vbyte) };
  }

  async sendCoins(a: SendCoinsArgs): Promise<{ txid: string }> {
    if (!isMainnetAddress(a.address)) throw new WithdrawError("bad address");
    if (a.sendAll === (a.amountSat !== undefined)) throw new WithdrawError("give exactly one of amountSat or sendAll");
    const body: Record<string, unknown> = { addr: a.address.trim(), sat_per_vbyte: posInt(a.satPerVbyte, "fee rate") };
    if (a.sendAll) body.send_all = true;
    else body.amount = posInt(a.amountSat!, "amount");
    const r = await this.call("POST", "/v1/transactions", body);
    if (!/^[0-9a-f]{64}$/.test(String(r.txid ?? ""))) throw new WithdrawError("LND returned no txid");
    return { txid: r.txid };
  }

  async decodeInvoice(invoice: string): Promise<DecodedInvoice> {
    const inv = normalizeInvoice(invoice);
    if (!inv) throw new WithdrawError("bad invoice");
    const r = await this.call("GET", `/v1/payreq/${inv}`);
    return {
      destination: String(r.destination ?? ""),
      paymentHash: String(r.payment_hash ?? ""),
      amountSat: toNum(r.num_satoshis),
      description: String(r.description ?? ""),
      expiresAt: toNum(r.timestamp) + toNum(r.expiry || 3600),
    };
  }

  /** amountSat only for amountless invoices. feeLimitSat is a hard routing-fee cap. */
  async payInvoice(invoice: string, feeLimitSat: number, amountSat?: number): Promise<PayResult> {
    const inv = normalizeInvoice(invoice);
    if (!inv) throw new WithdrawError("bad invoice");
    if (!Number.isSafeInteger(feeLimitSat) || feeLimitSat < 0) throw new WithdrawError("bad fee limit");
    const body: Record<string, unknown> = { payment_request: inv, fee_limit: { fixed: String(feeLimitSat) } };
    if (amountSat !== undefined) body.amt = posInt(amountSat, "amount");
    const r = await this.call("POST", "/v1/channels/transactions", body);
    // SendPaymentSync reports routing failures in a 200 body.
    if (r.payment_error) throw new WithdrawError(`payment failed: ${String(r.payment_error).slice(0, 120)}`);
    if (!r.payment_hash) throw new WithdrawError("LND returned no payment hash");
    return {
      paymentHashHex: b64ToHex(r.payment_hash),
      feeSat: toNum(r.payment_route?.total_fees),
    };
  }
}
