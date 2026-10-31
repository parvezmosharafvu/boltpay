// Owner-only node withdrawal: request handling for the node-withdraw
// edge function, kept here so it can be unit-tested with mocks.
//
// Read actions:  status, balances, decode, estimate (owner only, even with withdrawals OFF)
// Spend actions: send_onchain, pay_invoice
//   flag + owner -> step-up code -> system_node_withdraw_reserve
//   -> LND -> system_node_withdraw_finish -> ops alert.
// Step-up: 'stepup_request' with { request: <the spend body> } makes a
// random 6-digit code, sends it to the admin Telegram, and stores only
// HMAC(code, requestHash) (0113: 5 min, 5 attempts, single use).
// requestHash = SHA-256 of the canonical spend, so the code is bound to the
// exact action, destination, amount, fee rate and fee limit. A spend must
// carry stepUpCode; any mismatch is refused before reserve or LND.
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
  stepUpSecret: string;                           // server-only HMAC key for code hashes
  alert: (text: string) => Promise<unknown>; // nonsensitive ops alerts only
  sendStepupCode: (text: string) => Promise<boolean>; // confirmed owner Telegram delivery
  newCode?: () => string;                         // test hook
}

const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
const enc = new TextEncoder();

/** Canonical spend: fixed key order, normalised values. null = malformed. */
export function canonicalSpend(b: Record<string, unknown>): { text: string; summary: string } | null {
  const num = (v: unknown) => (v === undefined || v === null ? null : typeof v === "number" && Number.isSafeInteger(v) && v >= 0 ? v : NaN);
  const feeLimitSat = num(b.feeLimitSat), amountSat = num(b.amountSat);
  if (feeLimitSat === null || Number.isNaN(feeLimitSat) || Number.isNaN(amountSat)) return null;
  if (b.action === "send_onchain") {
    const address = String(b.address ?? "").trim();
    const satPerVbyte = num(b.satPerVbyte), sendAll = b.sendAll === true;
    if (!address || !satPerVbyte || Number.isNaN(satPerVbyte)) return null;
    const c = { action: "send_onchain", address, amountSat: sendAll ? null : amountSat, sendAll, satPerVbyte, feeLimitSat };
    return { text: JSON.stringify(c), summary: `${sendAll ? "ALL on-chain" : `${amountSat} sat on-chain`} to ${shortDest(address)}, ${satPerVbyte} sat/vB, fee limit ${feeLimitSat} sat` };
  }
  if (b.action === "pay_invoice") {
    const invoice = normalizeInvoice(String(b.invoice ?? ""));
    if (!invoice) return null;
    const c = { action: "pay_invoice", invoice, amountSat, feeLimitSat };
    return { text: JSON.stringify(c), summary: `Lightning ${amountSat ?? "invoice amount"}${amountSat ? " sat" : ""} to ${shortDest(invoice)}, fee limit ${feeLimitSat} sat` };
  }
  return null;
}

export async function requestHash(text: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", enc.encode(text)));
}

export async function codeHash(code: string, reqHash: string, secret: string): Promise<string> {
  const k = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", k, enc.encode(`${code}:${reqHash}`)));
}

export function randomCode(): string {
  // rejection sampling to avoid modulo bias
  const a = new Uint32Array(1);
  for (;;) { crypto.getRandomValues(a); if (a[0] < 4294000000) return String(a[0] % 1000000).padStart(6, "0"); }
}

export interface Result { status: number; body: Record<string, unknown> }
const ok = (body: Record<string, unknown>): Result => ({ status: 200, body });
const err = (status: number, error: string): Result => ({ status, body: { error } });

export const SPEND_ACTIONS = new Set(["send_onchain", "pay_invoice"]);
const READ_ACTIONS = new Set(["status", "balances", "decode", "estimate"]);

export function shortDest(d: string): string {
  const s = String(d);
  return s.length <= 16 ? s : `${s.slice(0, 8)}…${s.slice(-6)}`;
}

const int = (v: unknown) => (typeof v === "number" && Number.isSafeInteger(v) && v > 0 ? v : null);

/** Caller is already authenticated (verify_jwt + getUser) and has profile role. */
export async function handle(userId: string, role: string | null, body: Record<string, unknown>, d: Deps): Promise<Result> {
  const action = String(body.action ?? "");
  if (!READ_ACTIONS.has(action) && !SPEND_ACTIONS.has(action) && action !== "stepup_request") return err(400, "unknown action");

  // Authentication/authorization always comes before status or LND access.
  const owner = await d.setting("node_withdraw_owner_id");
  if (role !== "admin" || typeof owner !== "string" || owner !== userId) return err(403, "Not authorized");

  // A disabled withdrawal switch must never authorize spend or issue a code.
  // Owner-only inspection stays available so setup can be checked safely.
  const enabled = (await d.setting("node_withdraw_enabled")) === true;
  if (action === "status") return ok({ enabled });
  if (!enabled && (SPEND_ACTIONS.has(action) || action === "stepup_request")) {
    return err(403, "node withdraw is disabled");
  }

  // LND SendCoins cannot enforce an absolute on-chain fee cap; estimates
  // are not a guarantee. Fail closed for on-chain sends and step-up codes
  // until a capped, pre-signed transaction flow is implemented and audited.
  const requested = body.request;
  const requestedAction = requested && typeof requested === "object" && !Array.isArray(requested)
    ? (requested as Record<string, unknown>).action : null;
  if (action === "send_onchain" || (action === "stepup_request" && requestedAction === "send_onchain")) {
    return err(503, "On-chain withdrawals paused until hard fee-cap enforcement is available");
  }

  if (action === "stepup_request") {
    const req = (body.request ?? {}) as Record<string, unknown>;
    const c = canonicalSpend(req);
    if (!c) return err(400, "bad spend request");
    const rh = await requestHash(c.text);
    const code = (d.newCode ?? randomCode)();
    const { data: exp, error } = await d.rpc("system_node_withdraw_stepup_issue", {
      p_actor: userId, p_request_hash: rh, p_code_hash: await codeHash(code, rh, d.stepUpSecret),
    });
    if (error) return err(409, error.message ?? "step-up failed");
    // Never send a verification code via sendOpsAlert: that also forwards
    // messages to a generic webhook and may claim success for rejected HTTP.
    const message = `🔐 Node withdraw code ${code} (5 min, one use)\n${c.summary}\nIf this was not you, turn node_withdraw_enabled off.`;
    let delivered = false;
    try { delivered = await d.sendStepupCode(message); } catch { /* fail closed */ }
    if (!delivered) return err(503, "Telegram code delivery not confirmed. Link the owner Telegram account; do not proceed.");
    return ok({ status: "code_sent", expiresAt: exp });
  }

  if (SPEND_ACTIONS.has(action)) {
    const c = canonicalSpend(body);
    const code = String(body.stepUpCode ?? "");
    let passed = false;
    if (c && /^[0-9]{6}$/.test(code)) {
      const rh = await requestHash(c.text);
      const { data, error } = await d.rpc("system_node_withdraw_stepup_consume", {
        p_actor: userId, p_request_hash: rh, p_code_hash: await codeHash(code, rh, d.stepUpSecret),
      });
      passed = !error && data === true;
    }
    if (!passed) {
      await d.alert(`⚠️ Node withdraw ${action} refused: step-up code missing, wrong, expired or for a different request`);
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
        amountSat = (await lnd.balances()).onchainConfirmedSat; // reserve the whole confirmed balance
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

    let reference: string, feeSat: number | null;
    try {
      if (kind === "onchain") {
        // Kept unreachable until the wallet supports an enforceable on-chain
        // total fee cap, not merely an estimated fee.
        throw new WithdrawError("On-chain withdrawals paused");
      }
      const r = await lnd.payInvoice(destination, feeLimitSat, invoiceAmt);
      reference = r.paymentHashHex; feeSat = r.feeSat;
    } catch {
      // Even an HTTP error can arrive after LND accepted the payment.
      // Never guess that money has not moved or release this reservation.
      try {
        await d.alert(`⚠️ Node withdraw outcome unknown: ${amountSat} sat ${kind} to ${shortDest(destination)}`);
      } catch { /* notifications must not change financial outcome */ }
      return err(502, "send outcome unknown; do NOT retry; reconcile with LND payment records");
    }

    // LND returned success. A failed DB finalize must never look like a
    // normal success and must never cause an automatic second send.
    let finished = false;
    try {
      const { data, error } = await d.rpc("system_node_withdraw_finish", {
        p_id: id, p_status: "sent", p_reference: reference, p_fee_sat: feeSat, p_error: null,
      });
      finished = !error && data === true;
    } catch { /* remain reserved; requires reconciliation */ }
    if (!finished) {
      try { await d.alert(`🚨 Node payment sent but ledger finalize failed: ref ${reference.slice(0, 12)}; reconcile immediately; DO NOT RETRY`); }
      catch { /* best effort */ }
      return err(502, `LND reported payment sent, but the database did not confirm recording it. DO NOT RETRY. Reference: ${reference}`);
    }
    try { await d.alert(`💸 Node withdraw sent: ${amountSat} sat ${kind} to ${shortDest(destination)} (ref ${reference.slice(0, 12)})`); }
    catch { /* the successful payment is not rolled back by alert delivery */ }
    return ok({ status: "sent", id, reference, feeSat });
  } catch (e) {
    const msg = e instanceof WithdrawError ? e.message : "LND error";
    return err(502, msg);
  }
}
