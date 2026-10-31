import { assert, assertEquals } from "jsr:@std/assert@1";
import { canonicalSpend, codeHash, handle, randomCode, requestHash, shortDest, type Deps, type WithdrawLnd } from "./node_withdraw.ts";
import { sendNodeWithdrawStepup, sendOpsAlert, sendSettledAlert } from "./alerts.ts";
import { LndWithdrawClient, WithdrawError } from "./lnd_withdraw.ts";

const OWNER = "44444444-4444-4444-4444-444444444444";
const ADDR = "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq";
const INV = "lnbc2500u1pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdq5xysxxatsyp3k7enxv4jsxqzpu";
const MAC = "0201deadbeef";

function fakeLnd(over: Partial<WithdrawLnd> = {}) {
  const calls: string[] = [];
  const lnd: WithdrawLnd = {
    assertReady: async () => { calls.push("ready"); },
    balances: async () => { calls.push("balances"); return { onchainConfirmedSat: 40000, onchainUnconfirmedSat: 0, lightningLocalSat: 9000 }; },
    estimateFee: async () => { calls.push("estimate"); return { feeSat: 300, satPerVbyte: 2 }; },
    sendCoins: async () => { calls.push("sendCoins"); return { txid: "ab".repeat(32) }; },
    decodeInvoice: async () => { calls.push("decode"); return { destination: "02aa", paymentHash: "cd".repeat(32), amountSat: 250, description: "x", expiresAt: Date.now() / 1000 + 600 }; },
    payInvoice: async () => { calls.push("pay"); return { paymentHashHex: "cd".repeat(32), feeSat: 1 }; },
    trackPayment: async () => { calls.push("track"); return { status: "IN_FLIGHT", feeSat: 0 }; },
    ...over,
  };
  return { lnd, calls };
}

function deps(o: { enabled?: unknown; owner?: unknown; stepUp?: boolean; lnd?: WithdrawLnd | null; reserveErr?: string; finishErr?: string; finishReturn?: boolean; telegramDelivery?: boolean; pendingRows?: Array<{ id: number; kind: string; payment_hash: string | null }> } = {}) {
  const rpcs: { fn: string; args: any }[] = [];
  const stepRpcs: { fn: string; args: any }[] = [];
  const alerts: string[] = [];
  const stepupMessages: string[] = [];
  const d: Deps = {
    rpc: (fn, args) => {
      if (fn.startsWith("system_node_withdraw_stepup_")) {
        stepRpcs.push({ fn, args });
        return Promise.resolve({ data: fn.endsWith("consume") ? (o.stepUp ?? false) : "2026-10-31T01:05:00Z", error: null });
      }
      rpcs.push({ fn, args });
      if (fn === "system_node_withdraw_reserve_payment" && o.reserveErr) return Promise.resolve({ data: null, error: { message: o.reserveErr } });
      if (fn === "system_node_withdraw_finish" && o.finishErr) return Promise.resolve({ data: null, error: { message: o.finishErr } });
      return Promise.resolve({ data: fn === "system_node_withdraw_reserve_payment" ? 7 : fn === "system_node_withdraw_finish" ? (o.finishReturn ?? true) : true, error: null });
    },
    setting: async (k) => k === "node_withdraw_enabled" ? (o.enabled ?? true) : k === "node_withdraw_owner_id" ? ("owner" in o ? o.owner : OWNER) : null,
    lnd: async () => (o.lnd === undefined ? fakeLnd().lnd : o.lnd),
    stepUpSecret: "test-secret",
    alert: async (t) => { alerts.push(t); },
    sendStepupCode: async (t) => { stepupMessages.push(t); return o.telegramDelivery ?? true; },
    pending: async () => o.pendingRows ?? [],
  };
  return { d, rpcs, stepRpcs, alerts, stepupMessages };
}

Deno.test("flag off permits owner reads but never codes or spends", async () => {
  const f = fakeLnd();
  const { d, rpcs, stepRpcs, alerts } = deps({ enabled: false, lnd: f.lnd });
  assertEquals((await handle(OWNER, "admin", { action: "status" }, d)).body, { enabled: false });
  assertEquals((await handle(OWNER, "admin", { action: "balances" }, d)).status, 200);
  assertEquals((await handle(OWNER, "admin", { action: "decode", invoice: INV }, d)).status, 200);
  assertEquals((await handle(OWNER, "admin", { action: "estimate", address: ADDR, amountSat: 1000 }, d)).status, 200);
  const spend = { action: "send_onchain", address: ADDR, amountSat: 1000, satPerVbyte: 2, feeLimitSat: 100, stepUpCode: "123456", requestKey: "readonly-01" };
  assertEquals((await handle(OWNER, "admin", { action: "stepup_request", request: spend }, d)).status, 403);
  assertEquals((await handle(OWNER, "admin", spend, d)).status, 403);
  assertEquals((await handle(OWNER, "admin", { action: "pay_invoice", invoice: INV, feeLimitSat: 100, stepUpCode: "123456", requestKey: "readonly-02" }, d)).status, 403);
  assertEquals(f.calls, ["balances", "decode", "estimate"]);
  assertEquals(rpcs.length, 0);
  assertEquals(stepRpcs.length, 0);
  assertEquals(alerts.length, 0);
});

Deno.test("status does not require LND config; only owner admin may see it", async () => {
  assertEquals((await handle(OWNER, "admin", { action: "status" }, deps({ lnd: null }).d)).body, { enabled: true });
  assertEquals((await handle(OWNER, "admin", { action: "status" }, deps({ enabled: false, lnd: null }).d)).body, { enabled: false });
  assertEquals((await handle("other", "admin", { action: "status" }, deps({ enabled: false }).d)).status, 403);
  assertEquals((await handle(OWNER, "creator", { action: "status" }, deps({ enabled: false }).d)).status, 403);
  assertEquals((await handle(OWNER, "admin", { action: "status" }, deps({ owner: null }).d)).status, 403);
});

Deno.test("only the owner admin gets through", async () => {
  assertEquals((await handle("other", "admin", { action: "balances" }, deps().d)).status, 403);
  assertEquals((await handle(OWNER, "creator", { action: "balances" }, deps().d)).status, 403);
  assertEquals((await handle(OWNER, "admin", { action: "balances" }, deps({ owner: null }).d)).status, 403);
  assertEquals((await handle(OWNER, "admin", { action: "close_channel" }, deps().d)).status, 400);
});

Deno.test("read actions", async () => {
  const b = await handle(OWNER, "admin", { action: "balances" }, deps().d);
  assertEquals((b.body.balances as any).lightningLocalSat, 9000);
  const dec = await handle(OWNER, "admin", { action: "decode", invoice: INV }, deps().d);
  assertEquals((dec.body.invoice as any).amountSat, 250);
  const est = await handle(OWNER, "admin", { action: "estimate", address: ADDR, amountSat: 1000 }, deps().d);
  assertEquals((est.body.estimate as any).feeSat, 300);
  assertEquals((await handle(OWNER, "admin", { action: "estimate", address: "tb1qx", amountSat: 1 }, deps().d)).status, 400);
  assertEquals((await handle(OWNER, "admin", { action: "balances" }, deps({ lnd: null }).d)).status, 503);
});

Deno.test("refused step-up stops every spend before reserve or LND", async () => {
  for (const body of [
    { action: "pay_invoice", invoice: INV, feeLimitSat: 10, stepUpCode: "123456", requestKey: "key-000002" },
  ]) {
    const f = fakeLnd();
    const { d, rpcs, alerts } = deps({ lnd: f.lnd });
    const r = await handle(OWNER, "admin", body, d);
    assertEquals(r.status, 401);
    assertEquals(r.body.error, "step-up required");
    assertEquals(rpcs.length, 0);
    assertEquals(f.calls.length, 0);
    assertEquals(alerts.length, 1);
  }
});

Deno.test("on-chain spends and on-chain Telegram codes fail closed even if feature switch is ON", async () => {
  const f = fakeLnd();
  const { d, rpcs, stepRpcs, alerts } = deps({ enabled: true, lnd: f.lnd, stepUp: true });
  const spend = { action: "send_onchain", address: ADDR, amountSat: 1000, satPerVbyte: 2, feeLimitSat: 500, stepUpCode: "123456", requestKey: "onchain-no" };
  assertEquals((await handle(OWNER, "admin", { action: "stepup_request", request: spend }, d)).status, 503);
  assertEquals((await handle(OWNER, "admin", spend, d)).status, 503);
  assertEquals(f.calls, []);
  assertEquals(rpcs, []);
  assertEquals(stepRpcs, []);
  assertEquals(alerts, []);
});

Deno.test("reserve refusal stops before LND spend", async () => {
  const f = fakeLnd();
  const { d } = deps({ stepUp: true, lnd: f.lnd, reserveErr: "fee limit above node_withdraw_max_fee_sat" });
  const r = await handle(OWNER, "admin", { action: "pay_invoice", invoice: INV, feeLimitSat: 10, stepUpCode: "123456", requestKey: "key-000005" }, d);
  assertEquals(r.status, 409);
  assertEquals(r.body.error, "fee limit above node_withdraw_max_fee_sat");
  assert(!f.calls.includes("pay"));
});

Deno.test("lightning: amount must match invoice; LND failure retains reservation for reconciliation", async () => {
  assertEquals((await handle(OWNER, "admin", { action: "pay_invoice", invoice: INV, amountSat: 999, feeLimitSat: 10, stepUpCode: "123456", requestKey: "key-000006" }, deps({ stepUp: true }).d)).status, 400);
  const f = fakeLnd({ payInvoice: async () => { throw new WithdrawError("payment failed: no_route"); } });
  const { d, rpcs, alerts } = deps({ stepUp: true, lnd: f.lnd });
  const r = await handle(OWNER, "admin", { action: "pay_invoice", invoice: INV, feeLimitSat: 10, stepUpCode: "123456", requestKey: "key-000007" }, d);
  assertEquals(r.status, 502);
  assertEquals(rpcs.map((x) => x.fn), ["system_node_withdraw_reserve_payment"]);
  assert(alerts[0].includes("outcome unknown"));
  assert(String(r.body.error).includes("DO NOT retry") || String(r.body.error).includes("do NOT retry"));
});

Deno.test("Lightning timeout leaves the prior reservation in place", async () => {
  const f = fakeLnd({ payInvoice: async () => { throw new WithdrawError("LND unreachable: TimeoutError"); } });
  const { d, rpcs } = deps({ stepUp: true, lnd: f.lnd });
  const r = await handle(OWNER, "admin", { action: "pay_invoice", invoice: INV, feeLimitSat: 500, stepUpCode: "123456", requestKey: "key-000008" }, d);
  assertEquals(r.status, 502);
  assertEquals(rpcs.map((x) => x.fn), ["system_node_withdraw_reserve_payment"]);
});

Deno.test("successful LND transfer with failed or rejected database finish never reports success", async () => {
  for (const opts of [{ finishErr: "db unavailable" }, { finishReturn: false }]) {
    const f = fakeLnd();
    const { d, rpcs, alerts } = deps({ ...opts, stepUp: true, lnd: f.lnd });
    const r = await handle(OWNER, "admin", { action: "pay_invoice", invoice: INV, feeLimitSat: 30, stepUpCode: "123456", requestKey: "finish-err-01" }, d);
    assertEquals(r.status, 502);
    assert(String(r.body.error).includes("DO NOT RETRY"));
    assert(String(r.body.error).includes("cd".repeat(32)));
    assertEquals(f.calls.filter((x) => x === "pay").length, 1);
    assertEquals(rpcs.map((x) => x.fn), ["system_node_withdraw_reserve_payment", "system_node_withdraw_finish"]);
    assert(alerts.some((x) => x.includes("ledger finalize failed")));
  }
});

Deno.test("a failed Telegram notification cannot turn an already-recorded send into an error", async () => {
  const { d, rpcs } = deps({ stepUp: true });
  d.alert = async () => { throw new Error("Telegram offline"); };
  const r = await handle(OWNER, "admin", { action: "pay_invoice", invoice: INV, feeLimitSat: 10, stepUpCode: "123456", requestKey: "telegram-off-01" }, d);
  assertEquals(r.status, 200);
  assertEquals(rpcs.map(x => x.fn), ["system_node_withdraw_reserve_payment", "system_node_withdraw_finish"]);
});

Deno.test("same invoice hash is bound into SQL reservation", async () => {
  const f = fakeLnd();
  const { d, rpcs } = deps({ stepUp: true, lnd: f.lnd });
  const result = await handle(OWNER, "admin", { action: "pay_invoice", invoice: INV, feeLimitSat: 25, stepUpCode: "123456", requestKey: "unique-hash-test" }, d);
  assertEquals(result.status, 200);
  assertEquals(rpcs[0].fn, "system_node_withdraw_reserve_payment");
  assertEquals(rpcs[0].args.p_payment_hash, "cd".repeat(32));
});

Deno.test("owner reconciliation with transfers OFF never sends Lightning funds", async () => {
  const hash = "ab".repeat(32);
  const f = fakeLnd({ trackPayment: async (h) => {
    assertEquals(h, hash);
    return { status: "SUCCEEDED", feeSat: 4 };
  } });
  const { d, rpcs } = deps({ enabled: false, pendingRows: [{ id: 11, kind: "lightning", payment_hash: hash }], lnd: f.lnd });
  const result = await handle(OWNER, "admin", { action: "reconcile" }, d);
  assertEquals(result.body.reconciliation, { checked: 1, sent: 1, failed: 0, unresolved: 0 });
  assertEquals(rpcs.map(x => x.fn), ["system_node_withdraw_finish"]);
  assertEquals(rpcs[0].args.p_reference, hash);
  assert(!f.calls.includes("pay"));
  assertEquals((await handle("other", "admin", { action: "reconcile" }, d)).status, 403);
});

Deno.test("reconciliation never treats an in-flight or unknown payment as failed", async () => {
  for (const mode of ["IN_FLIGHT", "FAILED", "UNKNOWN", "throw"] as const) {
    const f = fakeLnd({ trackPayment: async () => {
      if (mode === "throw") throw new WithdrawError("LND tracking permission denied", 403);
      return { status: mode, feeSat: 0 };
    } });
    const { d, rpcs } = deps({ enabled: false, lnd: f.lnd, pendingRows: [{ id: 9, kind: "lightning", payment_hash: "ab".repeat(32) }] });
    const result = await handle(OWNER, "admin", { action: "reconcile" }, d);
    assertEquals(result.status, 200);
    const { checked, sent, failed, unresolved } = result.body.reconciliation as any;
    assertEquals(checked, 1);
    assertEquals(sent, 0);
    assertEquals(failed, mode === "FAILED" ? 1 : 0);
    assertEquals(unresolved, mode === "FAILED" ? 0 : 1);
    assertEquals(rpcs.length, mode === "FAILED" ? 1 : 0);
    assert(!f.calls.includes("pay"));
  }
});

Deno.test("end to end with mocked fetch: macaroon never in response or alert", async () => {
  const seen: string[] = [];
  const f = (async (u: string) => {
    seen.push(u);
    return new Response(JSON.stringify(u.includes("blockchain") ? { confirmed_balance: "5" } : { local_balance: { sat: "6" } }));
  }) as unknown as typeof fetch;
  const { d, alerts } = deps({ lnd: new LndWithdrawClient({ baseUrl: "https://lnd.test", macaroonHex: MAC }, f) });
  const r = await handle(OWNER, "admin", { action: "balances" }, d);
  assertEquals((r.body.balances as any).onchainConfirmedSat, 5);
  assertEquals(seen.length, 2);
  assert(!JSON.stringify(r.body).includes(MAC) && !alerts.join().includes(MAC));
});

Deno.test("sendOpsAlert posts to Telegram without logging; settled switch still works", async () => {
  const urls: string[] = [];
  const f = (async (u: string) => { urls.push(u); return new Response("{}"); }) as unknown as typeof fetch;
  const env = (m: Record<string, string>) => (k: string) => m[k];
  const n = await sendOpsAlert("hi", env({ ALERT_TELEGRAM_BOT_TOKEN: "T", ALERT_TELEGRAM_CHAT_ID: "1", ALERT_ON_SETTLED: "false" }), f);
  assertEquals(n, 1);
  assertEquals(urls[0], "https://api.telegram.org/botT/sendMessage");
  assertEquals(await sendSettledAlert("x", env({ ALERT_TELEGRAM_BOT_TOKEN: "T", ALERT_TELEGRAM_CHAT_ID: "1", ALERT_ON_SETTLED: "false" }), f), 0);
});

// In-memory stand-in for 0113 issue/consume, same rules as the SQL.
function stepUpDb() {
  let row: { rh: string; ch: string; attempts: number; used: boolean; exp: number } | null = null;
  return async (fn: string, a: any) => {
    if (fn === "system_node_withdraw_stepup_issue") { row = { rh: a.p_request_hash, ch: a.p_code_hash, attempts: 0, used: false, exp: Date.now() + 300000 }; return { data: new Date(row.exp).toISOString(), error: null }; }
    if (fn === "system_node_withdraw_stepup_consume") {
      if (!row || row.used || row.exp <= Date.now() || row.attempts >= 5) return { data: false, error: null };
      if (row.rh !== a.p_request_hash || row.ch !== a.p_code_hash) { if (++row.attempts >= 5) row.used = true; return { data: false, error: null }; }
      row.used = true; return { data: true, error: null };
    }
    return { data: fn === "system_node_withdraw_reserve_payment" ? 9 : true, error: null };
  };
}

Deno.test("step-up: code goes to confirmed owner Telegram only, bound to spend and used once", async () => {
  const { d, alerts, stepupMessages } = deps();
  const calls: { fn: string; args: any }[] = [];
  const db = stepUpDb();
  d.rpc = (fn, args) => { calls.push({ fn, args }); return db(fn, args); };
  d.newCode = () => "424242";
  const spend = { action: "pay_invoice", invoice: INV, amountSat: 1000, feeLimitSat: 500 };
  const r = await handle(OWNER, "admin", { action: "stepup_request", request: spend }, d);
  assertEquals(r.status, 200);
  assertEquals(r.body.status, "code_sent");
  assert(!JSON.stringify(r.body).includes("424242"), "code never returned to the browser");
  assert(stepupMessages[0].includes("424242") && stepupMessages[0].includes("1000 sat"));
  assert(!alerts.join(" ").includes("424242"), "ops/webhook must never see verification codes");
  const issued = calls[0].args;
  assertEquals(issued.p_request_hash.length, 64);
  assert(!JSON.stringify(issued).includes("424242"), "only the hash is stored");
  assertEquals(issued.p_code_hash, await codeHash("424242", issued.p_request_hash, "test-secret"));

  // different amount, address, fee rate or wrong code -> refused
  for (const bad of [{ amountSat: 1001 }, { invoice: INV + "x" }, { feeLimitSat: 501 }, { stepUpCode: "000000" }, { stepUpCode: undefined }]) {
    const x = await handle(OWNER, "admin", { ...spend, stepUpCode: "424242", requestKey: "key-bad-01", ...bad }, d);
    assertEquals(x.status, 401);
  }
  assert(!calls.some((c) => c.fn === "system_node_withdraw_reserve_payment"));
});

Deno.test("step-up delivery failure is fail-closed and never claims code_sent", async () => {
  const { d, rpcs, stepRpcs, alerts, stepupMessages } = deps({ telegramDelivery: false });
  d.newCode = () => "424242";
  const spend = { action: "pay_invoice", invoice: INV, feeLimitSat: 10 };
  const res = await handle(OWNER, "admin", { action: "stepup_request", request: spend }, d);
  assertEquals(res.status, 503);
  assert(String(res.body.error).includes("Telegram code delivery not confirmed"));
  assert(!JSON.stringify(res.body).includes("424242"));
  assertEquals(stepRpcs.map(x => x.fn), ["system_node_withdraw_stepup_issue"]);
  assertEquals(rpcs, []);
  assertEquals(alerts, []);
  assertEquals(stepupMessages.length, 1);
  d.sendStepupCode = async () => { throw new Error("Telegram offline"); };
  const thrown = await handle(OWNER, "admin", { action: "stepup_request", request: spend }, d);
  assertEquals(thrown.status, 503);
});

Deno.test("withdrawal OTP requires linked owner Telegram and explicit API acknowledgement", async () => {
  const got: { url: string; body: any }[] = [];
  const env = (values: Record<string, string>) => (k: string) => values[k];
  const good = { ALERT_TELEGRAM_BOT_TOKEN: "TEST_TOKEN", ALERT_WEBHOOK_URL: "https://webhook.test" };
  const f = (async (url: string, opts: RequestInit) => {
    got.push({ url, body: JSON.parse(String(opts.body)) });
    return new Response(JSON.stringify({ ok: true, result: { message_id: 1 } }), { status: 200 });
  }) as typeof fetch;
  assertEquals(await sendNodeWithdrawStepup("test code", undefined, env(good), f), false);
  assertEquals(await sendNodeWithdrawStepup("test code", "owner-chat", env(good), f), true);
  assertEquals(got.length, 1);
  assertEquals(got[0].url, "https://api.telegram.org/botTEST_TOKEN/sendMessage");
  assertEquals(got[0].body.chat_id, "owner-chat");
  assertEquals(got[0].body.text, "test code");
  const rejected = (async () => new Response(JSON.stringify({ ok: false }), { status: 200 })) as typeof fetch;
  const error = (async () => new Response(JSON.stringify({ ok: false }), { status: 403 })) as typeof fetch;
  const network = (async () => { throw new Error("network"); }) as typeof fetch;
  assertEquals(await sendNodeWithdrawStepup("x", "owner-chat", env(good), rejected), false);
  assertEquals(await sendNodeWithdrawStepup("x", "owner-chat", env(good), error), false);
  assertEquals(await sendNodeWithdrawStepup("x", "owner-chat", env(good), network), false);
  assertEquals(await sendNodeWithdrawStepup("x", "owner-chat", env({}), f), false);
});

Deno.test("step-up: right code spends once, reuse refused; 5 misses burn it", async () => {
  const { d } = deps();
  const db = stepUpDb();
  const fns: string[] = [];
  d.rpc = (fn, args) => { fns.push(fn); return db(fn, args); };
  d.newCode = () => "135790";
  const spend = { action: "pay_invoice", invoice: INV, feeLimitSat: 10 };
  await handle(OWNER, "admin", { action: "stepup_request", request: spend }, d);
  const ok = await handle(OWNER, "admin", { ...spend, stepUpCode: "135790", requestKey: "key-good-01" }, d);
  assertEquals(ok.status, 200);
  assert(fns.includes("system_node_withdraw_reserve_payment"));
  assertEquals((await handle(OWNER, "admin", { ...spend, stepUpCode: "135790", requestKey: "key-good-02" }, d)).status, 401);

  await handle(OWNER, "admin", { action: "stepup_request", request: spend }, d);
  for (let i = 0; i < 5; i++) await handle(OWNER, "admin", { ...spend, stepUpCode: "999999", requestKey: "key-miss-0" + i }, d);
  assertEquals((await handle(OWNER, "admin", { ...spend, stepUpCode: "135790", requestKey: "key-good-03" }, d)).status, 401);
});

Deno.test("step-up request is gated and validated", async () => {
  const spend = { action: "send_onchain", address: ADDR, amountSat: 1000, satPerVbyte: 2, feeLimitSat: 500 };
  assertEquals((await handle(OWNER, "admin", { action: "stepup_request", request: spend }, deps({ enabled: false }).d)).status, 403);
  assertEquals((await handle("other", "admin", { action: "stepup_request", request: spend }, deps().d)).status, 403);
  assertEquals((await handle(OWNER, "admin", { action: "stepup_request", request: { action: "close_channel" } }, deps().d)).status, 400);
  assertEquals(canonicalSpend({ ...spend, amountSat: -1 }), null);
  // canonical form ignores key order and requestKey
  const a = canonicalSpend({ ...spend, requestKey: "x" })!.text, b = canonicalSpend({ feeLimitSat: 500, satPerVbyte: 2, amountSat: 1000, address: ` ${ADDR} `, action: "send_onchain" })!.text;
  assertEquals(await requestHash(a), await requestHash(b));
  for (let i = 0; i < 50; i++) assert(/^[0-9]{6}$/.test(randomCode()));
});
