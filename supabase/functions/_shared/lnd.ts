// Minimal LND REST client for the LND checkout backend.
//
// Secrets (Supabase Edge Function secrets, or — when those env vars are
// missing — Supabase Vault 'lnd_rest_url' / 'lnd_invoice_macaroon', read via
// the service-role-only RPC system_lnd_config from migration 0074):
//   LND_REST_URL          https base URL of the LND REST proxy (Cloudflare Tunnel)
//   LND_INVOICE_MACAROON  hex macaroon baked with invoice-only permissions
//                         (invoices:read invoices:write address:write onchain:read)
//   CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET  optional Cloudflare Access
//                         service token in front of the tunnel
//
// The macaroon cannot send funds or close channels, so a leak cannot move
// money. It is still never logged or returned to a client.

export type LndInvoiceState = "OPEN" | "SETTLED" | "CANCELED" | "ACCEPTED";

export interface LndConfig {
  baseUrl: string;
  macaroonHex: string;
  cfAccessId?: string;
  cfAccessSecret?: string;
  timeoutMs?: number;
}

export interface AddInvoiceResult {
  rHashHex: string;
  paymentRequest: string;
  addIndex: string;
}

export interface LookupResult {
  state: LndInvoiceState;
  amtPaidMsat: bigint;
  settleDate: number;
}

export class LndNotConfiguredError extends Error {}
export class LndError extends Error {
  constructor(message: string, public status?: number) {
    super(message);
  }
}

/** Reads config from env. Returns null when either secret is missing. */
export function lndConfigFromEnv(
  get: (k: string) => string | undefined = (k) => Deno.env.get(k),
): LndConfig | null {
  const baseUrl = (get("LND_REST_URL") ?? "").trim().replace(/\/+$/, "");
  const macaroonHex = (get("LND_INVOICE_MACAROON") ?? "").trim();
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

let vaultCache: { cfg: LndConfig | null; at: number } | null = null;
const VAULT_MISS_TTL_MS = 60_000;

/** Test hook: forget the per-isolate Vault cache. */
export function resetLndConfigCache() {
  vaultCache = null;
}

/**
 * Env first (LND_REST_URL / LND_INVOICE_MACAROON); if missing, Vault via the
 * service-role-only RPC system_lnd_config. A found config is cached for the
 * life of the isolate; a miss is retried after a minute. Never logs values.
 */
export async function lndConfig(
  db: RpcClient,
  get: (k: string) => string | undefined = (k) => Deno.env.get(k),
): Promise<LndConfig | null> {
  const env = lndConfigFromEnv(get);
  if (env) return env;
  if (vaultCache && (vaultCache.cfg || Date.now() - vaultCache.at < VAULT_MISS_TTL_MS)) return vaultCache.cfg;
  let cfg: LndConfig | null = null;
  try {
    const { data, error } = await db.rpc("system_lnd_config");
    const row = (Array.isArray(data) ? data[0] : data) as { rest_url?: string; macaroon?: string } | null;
    if (!error && row) {
      cfg = lndConfigFromEnv((k) =>
        k === "LND_REST_URL" ? row.rest_url ?? undefined
        : k === "LND_INVOICE_MACAROON" ? row.macaroon ?? undefined
        : get(k)
      );
    } else if (error) {
      console.error("lnd config: vault rpc failed");
    }
  } catch {
    console.error("lnd config: vault rpc threw");
  }
  vaultCache = { cfg, at: Date.now() };
  return cfg;
}

export function base64ToHex(b64: string): string {
  const bin = atob(b64.replace(/-/g, "+").replace(/_/g, "/"));
  let out = "";
  for (let i = 0; i < bin.length; i++) out += bin.charCodeAt(i).toString(16).padStart(2, "0");
  return out;
}

export function isHash(h: string): boolean {
  return /^[0-9a-f]{64}$/.test(h);
}

export class LndClient {
  constructor(private cfg: LndConfig, private fetchFn: typeof fetch = fetch) {}

  private async call(method: "GET" | "POST", path: string, body?: unknown): Promise<any> {
    const headers: Record<string, string> = {
      "Grpc-Metadata-macaroon": this.cfg.macaroonHex,
    };
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
        signal: AbortSignal.timeout(this.cfg.timeoutMs ?? 10_000),
      });
    } catch (e) {
      throw new LndError(`LND unreachable: ${(e as Error).name}`);
    }
    const text = await res.text();
    if (!res.ok) {
      // Body may echo request details; keep only a short prefix.
      throw new LndError(`LND ${method} ${path.split("?")[0]} failed: ${res.status} ${text.slice(0, 120)}`, res.status);
    }
    try {
      return JSON.parse(text);
    } catch {
      throw new LndError("LND returned non-JSON");
    }
  }

  /**
   * Creates a public invoice. private:false means LND adds NO route hints,
   * exactly like paycashapp.site: the payer's wallet finds the node through
   * its public announced channels.
   */
  async addInvoice(valueSats: number, memo: string, expirySec: number): Promise<AddInvoiceResult> {
    if (!Number.isInteger(valueSats) || valueSats <= 0) throw new LndError("invalid sats");
    const r = await this.call("POST", "/v1/invoices", {
      value: String(valueSats),
      memo: memo.slice(0, 100),
      expiry: String(expirySec),
      private: false,
    });
    const rHashHex = base64ToHex(String(r.r_hash ?? ""));
    const paymentRequest = String(r.payment_request ?? "");
    if (!isHash(rHashHex) || !/^ln(bc|tb|bcrt)/i.test(paymentRequest)) {
      throw new LndError("LND addinvoice returned an unexpected shape");
    }
    return { rHashHex, paymentRequest, addIndex: String(r.add_index ?? "") };
  }

  async lookupInvoice(rHashHex: string): Promise<LookupResult> {
    if (!isHash(rHashHex)) throw new LndError("invalid hash");
    const r = await this.call("GET", `/v1/invoice/${rHashHex}`);
    const state = String(r.state ?? "OPEN") as LndInvoiceState;
    return {
      state,
      amtPaidMsat: BigInt(String(r.amt_paid_msat ?? "0")),
      settleDate: Number(r.settle_date ?? 0),
    };
  }

  /** New on-chain address for the optional BIP21 fallback. */
  async newAddress(): Promise<string> {
    const r = await this.call("GET", "/v1/newaddress?type=WITNESS_PUBKEY_HASH");
    const a = String(r.address ?? "");
    if (!/^(bc1|tb1|bcrt1)[a-z0-9]{20,90}$/.test(a)) throw new LndError("bad address");
    return a;
  }
}
