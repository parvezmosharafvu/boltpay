import { assertEquals } from "jsr:@std/assert";
import { creatorPaidText } from "./alerts.ts";
Deno.test("creator text per mode", () => {
  assertEquals(creatorPaidText(100, 97.5, "x"), "✅ Payment received: $100.00 via /x — you get $97.50 after $2.50 fee");
  assertEquals(creatorPaidText(102.5, 100, "x"), "✅ Payment received: $102.50 via /x — you get $100.00 after $2.50 fee");
  assertEquals(creatorPaidText(101.25, 98.75, "x"), "✅ Payment received: $101.25 via /x — you get $98.75 after $2.50 fee");
  assertEquals(creatorPaidText(10, 10, "x"), "✅ Payment received: $10.00 via /x");
});
