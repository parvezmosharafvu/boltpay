import { assertEquals } from "jsr:@std/assert@1";
import { chargedAmount, feeShares, quote, resolveMarkup } from "./pricing.ts";
import { parseLndSettings } from "./settings.ts";

const base = { linkMarkupEnabled: true, linkMarkupMin: 0, linkMarkupMax: 50 };

Deno.test("flag irrelevant: link fee applies, no global markup (0104/0105)", () => {
  const s = { ...base, linkMarkupEnabled: false };
  assertEquals(resolveMarkup({ link_cost_percent: 20, profile_cost_percent: 7 }, s), 20);
  assertEquals(resolveMarkup({}, s), 0);
  assertEquals(chargedAmount(100, resolveMarkup({}, s)), 100);
});

Deno.test("0105: link % only, no profile fallback", () => {
  assertEquals(resolveMarkup({ link_cost_percent: 20, profile_cost_percent: 7 }, base), 20);
  assertEquals(resolveMarkup({ link_cost_percent: "0", profile_cost_percent: 7 }, base), 0);
  assertEquals(resolveMarkup({ link_cost_percent: null, profile_cost_percent: "7" }, base), 0);
  assertEquals(resolveMarkup({}, base), 0);
});

Deno.test("link % clamped to the admin range; 0 stays 0", () => {
  const s = { ...base, linkMarkupMin: 5, linkMarkupMax: 15 };
  assertEquals(resolveMarkup({ link_cost_percent: 40 }, s), 15);
  assertEquals(resolveMarkup({ link_cost_percent: 1 }, s), 5);
  assertEquals(resolveMarkup({ link_cost_percent: 0 }, s), 0);
  assertEquals(resolveMarkup({ profile_cost_percent: 500 }, s), 0);
});

Deno.test("settings: flag defaults off, range defaults 0-50", () => {
  const s = parseLndSettings([{ key: "lnd_customer_markup_percent", value: 2.5 }]);
  assertEquals([s.linkMarkupEnabled, s.linkMarkupMin, s.linkMarkupMax, s.markupPercent], [false, 0, 50, 2.5]);
  const on = parseLndSettings([{ key: "link_markup_enabled", value: true }, { key: "link_markup_max_percent", value: 20 }]);
  assertEquals([on.linkMarkupEnabled, on.linkMarkupMax], [true, 20]);
  assertEquals(chargedAmount(100, resolveMarkup({ link_cost_percent: 12 }, on)), 112);
});

Deno.test("0107 creator mode: buyer pays base, creator nets minus fee", () => {
  const q = quote(100, 0, "creator", 2.5);
  assertEquals([q.total, q.buyerFeeUsd, q.creatorFeeUsd, q.creatorNet], [100, 0, 2.5, 97.5]);
});

Deno.test("0107 buyer mode: total includes fee, creator nets full base", () => {
  const q = quote(100, 0, "buyer", 2.5);
  assertEquals([q.total, q.buyerFeeUsd, q.creatorFeeUsd, q.creatorNet], [102.5, 2.5, 0, 100]);
});

Deno.test("0107 split mode: 50/50 with rounding", () => {
  const q = quote(100, 0, "split", 2.5);
  assertEquals([q.buyer, q.creator], [1.25, 1.25]);
  assertEquals([q.total, q.creatorNet], [101.25, 98.75]);
  const r = quote(33.33, 0, "split", 2.5); // 0.416625 -> 0.42 each side
  assertEquals([r.buyerFeeUsd, r.total, r.creatorFeeUsd, r.creatorNet], [0.42, 33.75, 0.42, 32.91]);
  assertEquals(feeShares("split", 2.555), { mode: "split", buyer: 1.278, creator: 1.277 });
});

Deno.test("0107 link extra fee stacks in every mode", () => {
  assertEquals(quote(100, 10, "creator", 2.5).total, 110);
  assertEquals(quote(100, 10, "buyer", 2.5).total, 112.75);
  assertEquals(quote(100, 10, "split", 2.5).total, 111.38); // 110 + 1.375
  assertEquals(quote(100, 10, "creator", 2.5).creatorNet, 107.25);
});

Deno.test("0107 unknown mode falls back to creator", () => {
  assertEquals(feeShares("weird", 2.5), { mode: "buyer", buyer: 2.5, creator: 0 });
});
