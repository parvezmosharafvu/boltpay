import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { isPaid, lookupAddress, minAcceptSats, summarize } from "./onchain.ts";
import { syncLndPayment } from "./lnd_settle.ts";

const A = "bc1qexampleaddressxxxxxxxxxxxxxxxxxxxxxxx";
const tx = (id: string, conf: boolean, v: number, addr = A) => ({
  txid: id.padEnd(64, "0"), status: { confirmed: conf }, vout: [{ scriptpubkey_address: addr, value: v }, { scriptpubkey_address: "bc1qother", value: 999 }],
});

Deno.test("summarize splits confirmed / mempool, ignores other outputs", () => {
  const v = summarize([tx("a", true, 6000), tx("b", false, 500), tx("c", true, 7, "bc1qnot")], A);
  assertEquals(v.confirmedSats, 6000);
  assertEquals(v.mempoolSats, 500);
  assertEquals(v.txid, "a".padEnd(64, "0"));
});

Deno.test("isPaid: exact, tolerance 0.5%, underpaid, unconfirmed", () => {
  assertEquals(minAcceptSats(14015), 14015 - 70);
  assertEquals(isPaid(summarize([tx("a", true, 14015)], A), 14015), true);
  assertEquals(isPaid(summarize([tx("a", true, 13945)], A), 14015), true);
  assertEquals(isPaid(summarize([tx("a", true, 13944)], A), 14015), false);
  assertEquals(isPaid(summarize([tx("a", false, 14015)], A), 14015), false);
  assertEquals(isPaid(summarize([], A), 14015), false);
});

Deno.test("lookupAddress rejects bad address and explorer errors", async () => {
  await assertRejects(() => lookupAddress("../etc", fetch));
  const f = (() => Promise.resolve(new Response("x", { status: 429 }))) as typeof fetch;
  await assertRejects(() => lookupAddress(A, f, "https://x"));
});

function fakeDb(settleResult = true) {
  const calls: { fn: string; args: unknown }[] = [];
  return {
    calls,
    db: {
      rpc: (fn: string, args: unknown) => {
        calls.push({ fn, args });
        return Promise.resolve({ data: fn === "system_settle_onchain_payment" ? settleResult : true, error: null });
      },
      from: () => { throw new Error("no table in test"); },
    },
  };
}
const row = (status: string, expMs: number) => ({
  id: "p1", user_id: "u1", status, lnd_r_hash: "ab".repeat(32),
  expires_at: new Date(expMs).toISOString(), btc_address: A, amount_sats: 14015,
});
const lndOpen = { lookupInvoice: () => Promise.resolve({ state: "OPEN", amtPaidMsat: 0n }) };
const lndPaid = { lookupInvoice: () => Promise.resolve({ state: "SETTLED", amtPaidMsat: 14015000n }) };

Deno.test("sync: confirmed on-chain payment settles via onchain rpc", async () => {
  const { db, calls } = fakeDb();
  // deno-lint-ignore no-explicit-any
  const out = await syncLndPayment(db as any, lndOpen as any, row("new", Date.now() + 1e6), Date.now(), () => Promise.resolve(summarize([tx("a", true, 14015)], A)));
  assertEquals(out, "settled");
  assertEquals(calls[0].fn, "system_settle_onchain_payment");
});

Deno.test("sync: mempool tx blocks expiry; nothing credited", async () => {
  const { db, calls } = fakeDb();
  // deno-lint-ignore no-explicit-any
  const out = await syncLndPayment(db as any, lndOpen as any, row("new", Date.now() - 1e6), Date.now(), () => Promise.resolve(summarize([tx("a", false, 14015)], A)));
  assertEquals(out, "open");
  assertEquals(calls.length, 0);
});

Deno.test("sync: lightning-expired row still settles on-chain; underpay never", async () => {
  const a = fakeDb();
  // deno-lint-ignore no-explicit-any
  assertEquals(await syncLndPayment(a.db as any, lndOpen as any, row("expired", Date.now() - 1e6), Date.now(), () => Promise.resolve(summarize([tx("a", true, 14015)], A))), "settled");
  const b = fakeDb();
  // deno-lint-ignore no-explicit-any
  assertEquals(await syncLndPayment(b.db as any, lndOpen as any, row("expired", Date.now() - 1e6), Date.now(), () => Promise.resolve(summarize([tx("a", true, 100)], A))), "open");
  assertEquals(b.calls.length, 0);
});

Deno.test("sync: lightning paid first wins, address not consulted", async () => {
  const { db, calls } = fakeDb();
  let looked = false;
  // deno-lint-ignore no-explicit-any
  await syncLndPayment(db as any, lndPaid as any, row("new", Date.now() + 1e6), Date.now(), () => { looked = true; return Promise.resolve(summarize([], A)); });
  assertEquals(looked, false);
  assertEquals(calls[0].fn, "system_settle_lnd_payment");
});
