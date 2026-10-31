import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  isMainnetAddress,
  LndWithdrawClient,
  normalizeInvoice,
  WITHDRAW_MACAROON_URIS,
  withdrawConfig,
  withdrawConfigFromEnv,
} from "./lnd_withdraw.ts";

const MAC = "0201deadbeef";
const cfg = { baseUrl: "https://lnd.example.test", macaroonHex: MAC };
const ADDR = "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq";
const INV = "lnbc2500u1pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdq5xysxxatsyp3k7enxv4jsxqzpu";

type Call = { url: string; method: string; headers: Headers; body: any };
function mock(reply: (c: Call) => unknown, status = 200) {
  const calls: Call[] = [];
  const f = (async (u: string, init: RequestInit) => {
    const c = { url: u, method: init.method ?? "GET", headers: new Headers(init.headers), body: init.body ? JSON.parse(String(init.body)) : undefined };
    calls.push(c);
    return new Response(JSON.stringify(reply(c)), { status });
  }) as unknown as typeof fetch;
  return { f, calls };
}

Deno.test("macaroon is URI-scoped: no channel, peer, macaroon or stop RPCs", () => {
  for (const u of WITHDRAW_MACAROON_URIS) {
    assert(u.startsWith("uri:/lnrpc.Lightning/"), u);
    assert(!/Channel(?!Balance)|Peer|Macaroon|Stop|Policy|Backup|Abandon|Debug/.test(u), u);
  }
  assertEquals(WITHDRAW_MACAROON_URIS.length, 7);
});

Deno.test("config needs LND_WITHDRAW_MACAROON, not the invoice macaroon", () => {
  const env = (m: Record<string, string>) => (k: string) => m[k];
  assertEquals(withdrawConfigFromEnv(env({ LND_REST_URL: "https://x", LND_INVOICE_MACAROON: "ab" })), null);
  assertEquals(withdrawConfigFromEnv(env({ LND_REST_URL: "http://x", LND_WITHDRAW_MACAROON: "ab" })), null);
  assertEquals(withdrawConfigFromEnv(env({ LND_REST_URL: "https://x", LND_WITHDRAW_MACAROON: "zz" })), null);
  assertEquals(withdrawConfigFromEnv(env({ LND_REST_URL: "https://x/", LND_WITHDRAW_MACAROON: "ab" }))?.baseUrl, "https://x");
});

Deno.test("vault fallback uses system_lnd_withdraw_config", async () => {
  let fn = "";
  const db = { rpc: (f: string) => { fn = f; return Promise.resolve({ data: [{ rest_url: "https://v", macaroon: "abcd" }], error: null }); } };
  const c = await withdrawConfig(db, () => undefined);
  assertEquals(fn, "system_lnd_withdraw_config");
  assertEquals(c?.baseUrl, "https://v");
});

Deno.test("address and invoice shape checks", () => {
  assert(isMainnetAddress(ADDR));
  assert(isMainnetAddress("3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy"));
  assert(!isMainnetAddress("tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"));
  assert(!isMainnetAddress("bc1q evil"));
  assertEquals(normalizeInvoice("lightning:" + INV.toUpperCase()), INV);
  assertEquals(normalizeInvoice("lntb1xxxxxxxxxxxxxxxxxxxxxxxxx"), null);
});

Deno.test("balances read both endpoints with the macaroon header", async () => {
  const { f, calls } = mock((c) => c.url.endsWith("blockchain")
    ? { confirmed_balance: "120000", unconfirmed_balance: "5" }
    : { local_balance: { sat: "80000" } });
  const b = await new LndWithdrawClient(cfg, f).balances();
  assertEquals(b, { onchainConfirmedSat: 120000, onchainUnconfirmedSat: 5, lightningLocalSat: 80000 });
  assertEquals(calls[0].headers.get("Grpc-Metadata-macaroon"), MAC);
});

Deno.test("sendCoins: amount or send_all, never both", async () => {
  const { f, calls } = mock(() => ({ txid: "ab".repeat(32) }));
  const c = new LndWithdrawClient(cfg, f);
  await c.sendCoins({ address: ADDR, amountSat: 10000, satPerVbyte: 3 });
  assertEquals(calls[0].url, "https://lnd.example.test/v1/transactions");
  assertEquals(calls[0].body, { addr: ADDR, sat_per_vbyte: "3", amount: "10000" });
  await c.sendCoins({ address: ADDR, sendAll: true, satPerVbyte: 2 });
  assertEquals(calls[1].body, { addr: ADDR, sat_per_vbyte: "2", send_all: true });
  await assertRejects(() => c.sendCoins({ address: ADDR, amountSat: 1, sendAll: true, satPerVbyte: 1 }));
  await assertRejects(() => c.sendCoins({ address: ADDR, satPerVbyte: 1 }));
  await assertRejects(() => c.sendCoins({ address: "tb1qbad", amountSat: 1, satPerVbyte: 1 }));
  assertEquals(calls.length, 2);
});

Deno.test("payInvoice sets a fixed fee limit and surfaces payment_error", async () => {
  const ok = mock(() => ({ payment_hash: btoa("\xab".repeat(32)), payment_route: { total_fees: "4" } }));
  const r = await new LndWithdrawClient(cfg, ok.f).payInvoice(INV, 50);
  assertEquals(ok.calls[0].url, "https://lnd.example.test/v1/channels/transactions");
  assertEquals(ok.calls[0].body, { payment_request: INV, fee_limit: { fixed: "50" } });
  assertEquals(r, { paymentHashHex: "ab".repeat(32), feeSat: 4 });
  const bad = mock(() => ({ payment_error: "no_route" }));
  await assertRejects(() => new LndWithdrawClient(cfg, bad.f).payInvoice(INV, 50), Error, "no_route");
});

Deno.test("decodeInvoice maps fields", async () => {
  const { f, calls } = mock(() => ({ destination: "02aa", payment_hash: "cd", num_satoshis: "250000", description: "x", timestamp: "100", expiry: "60" }));
  const d = await new LndWithdrawClient(cfg, f).decodeInvoice(INV);
  assertEquals(calls[0].url, `https://lnd.example.test/v1/payreq/${INV}`);
  assertEquals(d.amountSat, 250000);
  assertEquals(d.expiresAt, 160);
});

Deno.test("assertReady refuses testnet or unsynced nodes", async () => {
  await assertRejects(() => new LndWithdrawClient(cfg, mock(() => ({ synced_to_chain: true, chains: [{ network: "testnet" }] })).f).assertReady());
  await assertRejects(() => new LndWithdrawClient(cfg, mock(() => ({ synced_to_chain: false, chains: [{ network: "mainnet" }] })).f).assertReady());
  await new LndWithdrawClient(cfg, mock(() => ({ synced_to_chain: true, chains: [{ network: "mainnet" }] })).f).assertReady();
});

Deno.test("errors never contain the macaroon or the invoice", async () => {
  const { f } = mock(() => ({ error: "boom" }), 500);
  const e = await assertRejects(() => new LndWithdrawClient(cfg, f).decodeInvoice(INV));
  assert(!String((e as Error).message).includes(MAC));
  assert(!String((e as Error).message).includes(INV));
});
