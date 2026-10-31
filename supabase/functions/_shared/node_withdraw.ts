// Owner-only node withdrawal: request handling for the node-withdraw
// edge function, kept here so it can be unit-tested with mocks.
//
// Read actions:  balances, decode, estimate
// Spend actions: send_onchain, pay_invoice
//   flag + owner -> fresh step-up token -> system_node_withdraw_reserve
//   -> LND -> system_node_withdraw_finish -> ops alert.
// Step-up is not built yet, so the default verifier rejects every spend
// with 'step-up required' before anything is reserved or sent.
//
// No channel, peer or stop calls (see lnd_withdraw.ts). Never logs or
// returns secrets; alerts carry only a shortened destination.
import { isMainnetAddress, normalizeInvoice, WithdrawError } from "./lnd_withdraw.ts";
import type { Balances, DecodedInvoice, PayResult } from "./lnd_withdraw.ts";

export interface WithdrawLnd {
  assertReady(): Promise<void>;
  balances(): Promise<Balances>;
  estimateFee(address: string, amountSat: number, targetConf?: number): Promise<{ feeSat: number; satPerVbyte: number }>;
  sendCoins(a: { address: string; satPerVbyte: number; amountSat?: number; sendAll?: boolean }): Promise<{ txid: string }>;
  decodeInvoice(invoice: string): Promise<DecodedInvoice>;
  payInvoice(invoice: string, feeLimitSat: number, amountSat?: number): Promise<PayResult>;
}

type Rpc = (fn: string, args?: Record<string, unknown>) => PromiseLike<{ data: unknown; error: { message?: string } | null }>;

export interface Deps {
  rpc: Rpc;                                       // service-role client
  setting: (key: string) => Promise<unknown>;     // app_settings value (parsed jsonb)
  lnd: () => Promise<WithdrawLnd | null>;         // null = not configured
  verifyStepUp: (userId: string, token: unknown) => Promise<boolean>;
  alert: (text: string) => Promise<unknown>;
}

/** Until step-up exists every spend is refused. */
export const rejectAllStepUp = (_u: string, _t: unknown) => Promise.resolve(false);

export interface Result { status: number; body: Record<string, unknown> }
const ok = (body: Record<string, unknown>): Result => ({ status: 200, body });
const err = (status: number, error: string): Result => ({ status, body: { error } });

export const SPEND_ACTIONS = new Set(["send_onchain", "pay_invoice"]);
const READ_ACTIONS = new Set(["balances", "decode", "estimate"]);

export function shortDest(d: string): string {
  const s = String(d);
  return s.length <= 16 ? s : `${s.slice(0, 8)}…${s.slice(-6)}`;
}

const int = (v: unknown) => (typeof v === "number" && Number.isSafeInteger(v) && v > 0 ? v : null);

/** Caller is already authenticated (verify_jwt + getUser) and has profile role. */
export async function handle(userId: string, role: string | null, body: Record<string, unknown>, d: Deps): Promise<Result> {
  const action = String(body.action ?? "");
  if (!READ_ACTIONS.has(action) && !SPEND_ACTIONS.has(action)) return err(400, "unknown action");

  if ((await d.setting("node_withdraw_enabled")) !== true) return err(403, "node withdraw is disabled");
  const owner = await d.setting("node_withdraw_owner_id");
  if (role !== "admin" || typeof owner !== "string" || owner !== userId) return err(403, "Not authorized");

  if (SPEND_ACTIONS.has(action)) {
    if (!(await d.verifyStepUp(userId, body.stepUpToken))) {
      await d.alert(`⚠️ Node withdraw ${action} refused: step-up required`);
      return err(401, "step-up required");
    }
  }

  const lnd = await d.lnd();
  if (!lnd) return err(503, "LND withdraw not configured");

  try {
    if (action === "balances") return ok({ balances: await lnd.balances() });

    if (action === "decode") {
      const inv = normalizeInvoice(String(body.invoice ?? ""));
      if (!inv) return err(400, "bad invoice");
      return ok({ invoice: await lnd.decodeInvoice(inv) });
    }

    if (action === "estimate") {
      const address = String(body.address ?? "").trim();
      const amountSat = int(body.amountSat);
      if (!isMainnetAddress(address) || !amountSat) return err(400, "bad address or amount");
      return ok({ estimate: await lnd.estimateFee(address, amountSat, int(body.targetConf) ?? 6) });
    }

    const requestKey = String(body.requestKey ?? "");
    if (!/^[A-Za-z0-9_-]{8,128}$/.test(requestKey)) return err(400, "bad requestKey");
    const feeLimitSat = typeof body.feeLimitSat === "number" && Number.isSafeInteger(body.feeLimitSat) && body.feeLimitSat >= 0 ? body.feeLimitSat : null;
    if (feeLimitSat === null) return err(400, "bad feeLimitSat");

    let kind: "onchain" | "lightning", destination: string, amountSat: number;
    let sendAll = false, satPerVbyte = 0, invoiceAmt: number | undefined;
    if (action === "send_onchain") {
      kind = "onchain";
      destination = String(body.address ?? "").trim();
      if (!isMainnetAddress(destination)) return err(400, "bad address");
      satPerVbyte = int(body.satPerVbyte) ?? 0;
      if (!satPerVbyte) return err(400, "bad satPerVbyte");
      sendAll = body.sendAll === true;
      if (sendAll) {
        if (body.amountSat !== undefined) return err(400, "amountSat and sendAll are exclusive");
        amountSat = (await lnd.balances()).onchainConfirmedSat; // reserve the whole balance under the cap
      } else {
        amountSat = int(body.amountSat) ?? 0;
      }
      if (!amountSat) return err(400, "bad amount");
    } else {
      kind = "lightning";
      const inv = normalizeInvoice(String(body.invoice ?? ""));
      if (!inv) return err(400, "bad invoice");
      destination = inv;
      const dec = await lnd.decodeInvoice(inv);
      if (dec.expiresAt * 1000 <= Date.now()) return err(400, "invoice expired");
      if (dec.amountSat > 0) {
        if (body.amountSat !== undefined && body.amountSat !== dec.amountSat) return err(400, "amount does not match invoice");
        amountSat = dec.amountSat;
      } else {
        amountSat = int(body.amountSat) ?? 0;
        if (!amountSat) return err(400, "amountless invoice needs amountSat");
        invoiceAmt = amountSat;
      }
    }

    await lnd.assertReady();

    const { data: id, error: rErr } = await d.rpc("system_node_withdraw_reserve", {
      p_actor: userId, p_kind: kind, p_destination: destination,
      p_amount_sat: amountSat, p_fee_limit_sat: feeLimitSat, p_request_key: requestKey,
    });
    if (rErr || id == null) return err(409, rErr?.message ?? "reserve failed");

    try {
      let reference: string, feeSat: number | null;
      if (kind === "onchain") {
        const r = await lnd.sendCoins(sendAll
          ? { address: destination, satPerVbyte, sendAll: true }
          : { address: destination, satPerVbyte, amountSat });
        reference = r.txid; feeSat = null;
      } else {
        const r = await lnd.payInvoice(destination, feeLimitSat, invoiceAmt);
        reference = r.paymentHashHex; feeSat = r.feeSat;
      }
      await d.rpc("system_node_withdraw_finish", { p_id: id, p_status: "sent", p_reference: reference, p_fee_sat: feeSat, p_error: null });
      await d.alert(`💸 Node withdraw sent: ${amountSat} sat ${kind} to ${shortDest(destination)} (ref ${reference.slice(0, 12)})`);
      return ok({ status: "sent", id, reference, feeSat });
    } catch (e) {
      // Ambiguous for on-chain: LND may have broadcast. Leave the row
      // 'reserved' (still counts against the cap) unless LND said no.
      const definite = e instanceof WithdrawError && (e.status ?? 0) >= 400 || String((e as Error).message).startsWith("payment failed");
      if (definite) {
        await d.rpc("system_node_withdraw_finish", { p_id: id, p_status: "failed", p_reference: null, p_fee_sat: null, p_error: (e as Error).message });
      }
      await d.alert(`❌ Node withdraw ${definite ? "failed" : "outcome unknown"}: ${amountSat} sat ${kind} to ${shortDest(destination)}`);
      return err(502, definite ? "send failed" : "send outcome unknown; check the node before retrying");
    }
  } catch (e) {
    const msg = e instanceof WithdrawError ? e.message : "LND error";
    return err(502, msg);
  }
}
