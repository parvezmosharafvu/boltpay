import { assert, assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import { base64ToHex, LndClient, lndConfigFromEnv } from "./lnd.ts";
import { chargedAmount, usdToSats, withinLimits, parseUsd } from "./pricing.ts";
import { combineRates } from "./rate.ts";
import { parseLndSettings } from "./settings.ts";

const HASH_B64 = btoa(String.fromCharCode(...new Uint8Array(32).fill(0xab)));
const cfg = { baseUrl: "https://lnd.example.test", macaroonHex: "0201abcd" };

Deno.test("base64 r_hash becomes 64-char hex", () => {
  assertEquals(base64ToHex(HASH_B64), "ab".repeat(32));
});

Deno.test("addInvoice sends private:false (no route hints), expiry and macaroon header", async () => {
  let sent: any, headers: Headers | undefined, url = "";
  const f = (async (u: string, init: RequestInit) => {
    url = u;
    headers = new Headers(init.headers);
    sent = JSON.parse(String(init.body));
    return new Response(JSON.stringify({ r_hash: HASH_B64, payment_request: "lnbc100u1ptest", add_index: "7" }));
  }) as unknown as typeof fetch;
  const r = await new LndClient(cfg, f).addInvoice(10000, "boltpay x", 3600);
  assertEquals(url, "https://lnd.example.test/v1/invoices");
  assertEquals(sent.private, false);
  assertEquals(sent.expiry, "3600");
  assertEquals(sent.value, "10000");
  assert(!("route_hints" in sent));
  assertEquals(headers!.get("Grpc-Metadata-macaroon"), "0201abcd");
  assertEquals(r.rHashHex, "ab".repeat(32));
});

Deno.test("LND error message never contains the macaroon", async () => {
  const f = (async () => new Response("nope", { status: 500 })) as unknown as typeof fetch;
  const e = await assertRejects(() => new LndClient(cfg, f).lookupInvoice("ab".repeat(32)));
  assert(!String((e as Error).message).includes("0201abcd"));
});

Deno.test("lookupInvoice parses state and msat", async () => {
  const f = (async () => new Response(JSON.stringify({ state: "SETTLED", amt_paid_msat: "10000000", settle_date: "1" }))) as unknown as typeof fetch;
  const r = await new LndClient(cfg, f).lookupInvoice("ab".repeat(32));
  assertEquals(r.state, "SETTLED");
  assertEquals(r.amtPaidMsat, 10000000n);
});

Deno.test("config requires https URL and hex macaroon", () => {
  const env = (m: Record<string, string>) => (k: string) => m[k];
  assertEquals(lndConfigFromEnv(env({})), null);
  assertEquals(lndConfigFromEnv(env({ LND_REST_URL: "http://x", LND_INVOICE_MACAROON: "ab" })), null);
  assertEquals(lndConfigFromEnv(env({ LND_REST_URL: "https://x", LND_INVOICE_MACAROON: "zz" })), null);
  assertEquals(lndConfigFromEnv(env({ LND_REST_URL: "https://x/", LND_INVOICE_MACAROON: "ab" }))?.baseUrl, "https://x");
});

Deno.test("limits $10–$1000", () => {
  assertEquals(withinLimits(9.99, 10, 1000), false);
  assertEquals(withinLimits(10, 10, 1000), true);
  assertEquals(withinLimits(1000, 10, 1000), true);
  assertEquals(withinLimits(1000.01, 10, 1000), false);
  assertEquals(parseUsd("abc"), null);
});

Deno.test("pricing maths", () => {
  assertEquals(chargedAmount(10, 5), 10.5);
  assertEquals(chargedAmount(10, -5), 10);
  assertEquals(chargedAmount(10, 5000), 110);
  assertEquals(usdToSats(10, 100000), 10000);
  assertEquals(usdToSats(10.01, 100000), 10010);
  assertThrows(() => usdToSats(0, 100000));
});

Deno.test("rate sources must agree within 2%", () => {
  assertEquals(combineRates(100000, 101000), 100500);
  assertThrows(() => combineRates(100000, 103000));
  assertThrows(() => combineRates(NaN, 100000));
});

Deno.test("settings default to off, 10/1000/3600", () => {
  const s = parseLndSettings([]);
  assertEquals(s, { enabled: false, onchainFallback: false, minUsd: 10, maxUsd: 1000, expirySec: 3600, markupPercent: 10 });
  assertEquals(parseLndSettings([{ key: "lnd_checkout_enabled", value: "true" }]).enabled, false);
  assertEquals(parseLndSettings([{ key: "lnd_checkout_enabled", value: true }]).enabled, true);
});

import { sendSettledAlert, settledAlertText } from "./alerts.ts";

Deno.test("settled alert: both channels, respects ALERT_ON_SETTLED=false", async () => {
  const urls: string[] = [];
  const f = (async (u: string) => { urls.push(u); return new Response("ok"); }) as unknown as typeof fetch;
  const env = (m: Record<string, string>) => (k: string) => m[k];
  const all = { ALERT_WEBHOOK_URL: "https://hook.test/x", ALERT_TELEGRAM_BOT_TOKEN: "t", ALERT_TELEGRAM_CHAT_ID: "1" };
  assertEquals(await sendSettledAlert("hi", env(all), f), 2);
  assertEquals(urls.length, 2);
  assertEquals(await sendSettledAlert("hi", env({ ...all, ALERT_ON_SETTLED: "false" }), f), 0);
  assertEquals(await sendSettledAlert("hi", env({}), f), 0);
  assertEquals(settledAlertText(12.5, "shop", "abcdef12-0000"), "✅ Payment settled (Lightning): $12.50 via /shop (payment abcdef12)");
});

Deno.test("lndConfig: env wins, else Vault RPC, cached per isolate", async () => {
  const { lndConfig, resetLndConfigCache } = await import("./lnd.ts");
  resetLndConfigCache();
  let calls = 0;
  const db = { rpc: (_fn: string) => { calls++; return Promise.resolve({ data: [{ rest_url: "https://lnd.example/", macaroon: "abcd" }], error: null }); } };
  const envCfg = await lndConfig(db, (k) => ({ LND_REST_URL: "https://env.example", LND_INVOICE_MACAROON: "ff" } as Record<string, string>)[k]);
  assertEquals(envCfg?.baseUrl, "https://env.example");
  assertEquals(calls, 0);
  const v1 = await lndConfig(db, () => undefined);
  const v2 = await lndConfig(db, () => undefined);
  assertEquals(v1?.baseUrl, "https://lnd.example");
  assertEquals(v2?.macaroonHex, "abcd");
  assertEquals(calls, 1);
  resetLndConfigCache();
  const bad = { rpc: () => Promise.resolve({ data: null, error: { message: "denied" } }) };
  assertEquals(await lndConfig(bad, () => undefined), null);
  resetLndConfigCache();
});

Deno.test("min is floored at $10 and markup defaults to 10%", () => {
  const s = parseLndSettings([{ key: "lnd_pay_min_usd", value: 1 }, { key: "lnd_customer_markup_percent", value: 7 }]);
  assertEquals(s.minUsd, 10);
  assertEquals(s.markupPercent, 7);
  assertEquals(parseLndSettings([{ key: "lnd_pay_min_usd", value: 25 }]).minUsd, 25);
  assertEquals(parseLndSettings([{ key: "lnd_customer_markup_percent", value: "bad" }]).markupPercent, 10);
  assertEquals(parseLndSettings([{ key: "lnd_customer_markup_percent", value: 0 }]).markupPercent, 0);
});

Deno.test("$10 entered is charged $11.00 at the default markup", () => {
  assertEquals(chargedAmount(10, parseLndSettings([]).markupPercent), 11);
});
