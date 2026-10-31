import { assertEquals } from "jsr:@std/assert";
import { creatorPaidText } from "./alerts.ts";
Deno.test("creator text: net amount and name with extra-fee percent", () => {
  assertEquals(creatorPaidText(97.5, "Luna", 27), "✅ Payment received: $97.50 · Luna 27%");
  assertEquals(creatorPaidText(10, "Nova", 0), "✅ Payment received: $10.00 · Nova");
  assertEquals(creatorPaidText(10, "Nova"), "✅ Payment received: $10.00 · Nova");
});
import { creatorShownAmount } from "./alerts.ts";
Deno.test("creator amount: base link amount, without extra fee or conversion fee", () => {
  // $100 link, 27% extra fee, 2.5% buyer conversion fee: paid 130.18, net 127
  assertEquals(creatorPaidText(creatorShownAmount("100.00", "127.00", 130.18), "Luna", 27), "✅ Payment received: $100.00 · Luna 27%");
  assertEquals(creatorShownAmount(null, 12.5, 13), 12.5);
  assertEquals(creatorShownAmount(0, null, 13), 13);
});
