import { assertEquals } from "jsr:@std/assert@1";
import { chargedAmount, resolveMarkup } from "./pricing.ts";
import { parseLndSettings } from "./settings.ts";

const base = { linkMarkupEnabled: true, linkMarkupMin: 0, linkMarkupMax: 50, markupPercent: 2.5 };

Deno.test("flag off: always the global markup", () => {
  const s = { ...base, linkMarkupEnabled: false };
  assertEquals(resolveMarkup({ link_cost_percent: 20, profile_cost_percent: 7 }, s), 2.5);
  assertEquals(resolveMarkup({}, s), 2.5);
});

Deno.test("flag on: link, then profile (>0), then global", () => {
  assertEquals(resolveMarkup({ link_cost_percent: 20, profile_cost_percent: 7 }, base), 20);
  assertEquals(resolveMarkup({ link_cost_percent: "0", profile_cost_percent: 7 }, base), 0);
  assertEquals(resolveMarkup({ link_cost_percent: null, profile_cost_percent: "7" }, base), 7);
  assertEquals(resolveMarkup({ link_cost_percent: null, profile_cost_percent: 0 }, base), 2.5);
  assertEquals(resolveMarkup({}, base), 2.5);
});

Deno.test("flag on: link/profile clamped to the admin range", () => {
  const s = { ...base, linkMarkupMin: 5, linkMarkupMax: 15 };
  assertEquals(resolveMarkup({ link_cost_percent: 40 }, s), 15);
  assertEquals(resolveMarkup({ link_cost_percent: 1 }, s), 5);
  assertEquals(resolveMarkup({ profile_cost_percent: 500 }, s), 15);
});

Deno.test("settings: flag defaults off, range defaults 0-50", () => {
  const s = parseLndSettings([{ key: "lnd_customer_markup_percent", value: 2.5 }]);
  assertEquals([s.linkMarkupEnabled, s.linkMarkupMin, s.linkMarkupMax, s.markupPercent], [false, 0, 50, 2.5]);
  const on = parseLndSettings([{ key: "link_markup_enabled", value: true }, { key: "link_markup_max_percent", value: 20 }]);
  assertEquals([on.linkMarkupEnabled, on.linkMarkupMax], [true, 20]);
  assertEquals(chargedAmount(100, resolveMarkup({ link_cost_percent: 12 }, on)), 112);
});
