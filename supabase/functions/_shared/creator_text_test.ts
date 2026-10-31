import { assertEquals } from "jsr:@std/assert";
import { creatorPaidText } from "./alerts.ts";
Deno.test("creator text: net amount and name with extra-fee percent", () => {
  assertEquals(creatorPaidText(97.5, "Luna", 27), "✅ Payment received: $97.50 · Luna 27%");
  assertEquals(creatorPaidText(10, "Nova", 0), "✅ Payment received: $10.00 · Nova");
  assertEquals(creatorPaidText(10, "Nova"), "✅ Payment received: $10.00 · Nova");
});
