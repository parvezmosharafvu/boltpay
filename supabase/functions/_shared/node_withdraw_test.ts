import { assert, assertEquals } from "jsr:@std/assert@1";
import { handle, rejectAllStepUp, shortDest, type Deps, type WithdrawLnd } from "./node_withdraw.ts";
import { sendOpsAlert, sendSettledAlert } from "./alerts.ts";
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
    decodeInvoice: async () => { calls.push("decode"); return { destination: "02aa", paymentHash: "cd", amountSat: 250, description: "x", expiresAt: Date.now() / 1000 + 600 }; },
    payInvoice: async () => { calls.push("pay"); return { paymentHashHex: "cd".repeat(32), feeSat: 1 }; },
    ...over,
  };
  return { lnd, calls };
}

function deps(o: { enabled?: unknown; owner?: unknown; stepUp?: boolean; lnd?: WithdrawLnd | null; reserveErr?: string } = {}) {
  const rpcs: { fn: string; args: any }[] = [];
  const alerts: string[] = [];
  const d: Deps = {
    rpc: (fn, args) => {
      rpcs.push({ fn, args });
      if (fn === "system_node_withdraw_reserve" && o.reserveErr) return Promise.resolve({ data: null, error: { message: o.reserveErr } });
      return Promise.resolve({ data: fn === "system_node_withdraw_reserve" ? 7 : true, error: null });
    },
    setting: async (k) => k === "node_withdraw_enabled" ? (o.enabled ?? true) : k === "node_withdraw_owner_id" ? ("owner" in o ? o.owner : OWNER) : null,
    lnd: async () => (o.lnd === undefined ? fakeLnd().lnd : o.lnd),
    verifyStepUp: async () => o.stepUp ?? false,
    alert: async (t) => { alerts.push(t); },
  };
  return { d, rpcs, alerts };
}

Deno.test("flag off refuses everything, even reads", async () => {
  const { d } = deps({ enabled: false });
  assertEquals((await handle(OWNER, "admin", { action: "balances" }, d)).status, 403);
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

Deno.test("default step-up rejects every spend before reserve or LND", async () => {
  assertEquals(await rejectAllStepUp(OWNER, "anything"), false);
  for (const body of [
    { action: "send_onchain", address: ADDR, amountSat: 1000, satPerVbyte: 2, feeLimitSat: 500, requestKey: "key-000001" },
    { action: "pay_invoice", invoice: INV, feeLimitSat: 10, requestKey: "key-000002" },
  ]) {
    const f = fakeLnd();
    const { d, rpcs, alerts } = deps({ lnd: f.lnd });
    d.verifyStepUp = rejectAllStepUp;
    const r = await handle(OWNER, "admin", body, d);
    assertEquals(r.status, 401);
    assertEquals(r.body.error, "step-up required");
    assertEquals(rpcs.length, 0);
    assertEquals(f.calls.length, 0);
    assertEquals(alerts.length, 1);
  }
});

Deno.test("on-chain spend: reserve -> sendCoins -> finish -> alert", async () => {
  const f = fakeLnd();
  const { d, rpcs, alerts } = deps({ stepUp: true, lnd: f.lnd });
  const r = await handle(OWNER, "admin", { action: "send_onchain", address: ADDR, amountSat: 1000, satPerVbyte: 2, feeLimitSat: 500, requestKey: "key-000003" }, d);
  assertEquals(r.status, 200);
  assertEquals(rpcs.map((x) => x.fn), ["system_node_withdraw_reserve", "system_node_withdraw_finish"]);
  assertEquals(rpcs[0].args.p_amount_sat, 1000);
  assertEquals(rpcs[1].args.p_status, "sent");
  assertEquals(f.calls, ["ready", "sendCoins"]);
  assert(alerts[0].includes(shortDest(ADDR)) && !alerts[0].includes(ADDR));
});

Deno.test("send-all reserves the confirmed balance", async () => {
  const { d, rpcs } = deps({ stepUp: true });
  await handle(OWNER, "admin", { action: "send_onchain", address: ADDR, sendAll: true, satPerVbyte: 2, feeLimitSat: 500, requestKey: "key-000004" }, d);
  assertEquals(rpcs[0].args.p_amount_sat, 40000);
});

Deno.test("cap / reserve refusal stops before LND spend", async () => {
  const f = fakeLnd();
  const { d } = deps({ stepUp: true, lnd: f.lnd, reserveErr: "daily cap exceeded" });
  const r = await handle(OWNER, "admin", { action: "pay_invoice", invoice: INV, feeLimitSat: 10, requestKey: "key-000005" }, d);
  assertEquals(r.status, 409);
  assertEquals(r.body.error, "daily cap exceeded");
  assert(!f.calls.includes("pay"));
});

Deno.test("lightning: amount must match invoice; failure marks failed", async () => {
  assertEquals((await handle(OWNER, "admin", { action: "pay_invoice", invoice: INV, amountSat: 999, feeLimitSat: 10, requestKey: "key-000006" }, deps({ stepUp: true }).d)).status, 400);
  const f = fakeLnd({ payInvoice: async () => { throw new WithdrawError("payment failed: no_route"); } });
  const { d, rpcs, alerts } = deps({ stepUp: true, lnd: f.lnd });
  const r = await handle(OWNER, "admin", { action: "pay_invoice", invoice: INV, feeLimitSat: 10, requestKey: "key-000007" }, d);
  assertEquals(r.status, 502);
  assertEquals(rpcs[1].args.p_status, "failed");
  assert(alerts[0].startsWith("❌ Node withdraw failed"));
});

Deno.test("unknown on-chain outcome leaves the reservation in place", async () => {
  const f = fakeLnd({ sendCoins: async () => { throw new WithdrawError("LND unreachable: TimeoutError"); } });
  const { d, rpcs } = deps({ stepUp: true, lnd: f.lnd });
  const r = await handle(OWNER, "admin", { action: "send_onchain", address: ADDR, amountSat: 1000, satPerVbyte: 2, feeLimitSat: 500, requestKey: "key-000008" }, d);
  assertEquals(r.status, 502);
  assertEquals(rpcs.map((x) => x.fn), ["system_node_withdraw_reserve"]);
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
