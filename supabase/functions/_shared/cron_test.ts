import { assert, assertEquals } from "jsr:@std/assert@1";
import { cronAuthorized, resetCronSecretCache, timingSafeEqual } from "./cron.ts";

const req = (h?: string) => new Request("https://x/", { headers: h ? { "x-cron-secret": h } : {} });
const vaultDb = (v: unknown, calls = { n: 0 }) => ({ rpc: () => { calls.n++; return Promise.resolve({ data: v, error: null }); } });

Deno.test("timingSafeEqual", () => {
  assert(timingSafeEqual("abc", "abc"));
  assert(!timingSafeEqual("abc", "abd"));
  assert(!timingSafeEqual("abc", "abcd"));
});

Deno.test("cronAuthorized: env, vault fallback, fail closed, cache", async () => {
  resetCronSecretCache();
  const calls = { n: 0 };
  const db = vaultDb("vs", calls);
  assert(await cronAuthorized(req("es"), db, () => "es"));
  assertEquals(calls.n, 0);
  assert(await cronAuthorized(req("vs"), db, () => undefined));
  assert(await cronAuthorized(req("vs"), db, () => "es"));
  assert(!(await cronAuthorized(req("nope"), db, () => undefined)));
  assert(!(await cronAuthorized(req(), db, () => undefined)));
  assertEquals(calls.n, 1);
  resetCronSecretCache();
  assert(!(await cronAuthorized(req("x"), vaultDb(null), () => undefined)));
  resetCronSecretCache();
});
