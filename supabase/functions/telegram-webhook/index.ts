// Telegram bot webhook: links a creator's chat when they send "/start CODE".
// Fails closed: without TELEGRAM_WEBHOOK_SECRET (matched against Telegram's
// X-Telegram-Bot-Api-Secret-Token header) every request is rejected.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

function reply(token: string, chatId: number, text: string) {
  return fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: chatId, text }),
  }).catch(() => undefined);
}

Deno.serve(async (req) => {
  const secret = Deno.env.get("TELEGRAM_WEBHOOK_SECRET");
  if (!secret || req.headers.get("x-telegram-bot-api-secret-token") !== secret) {
    return new Response("forbidden", { status: 403 });
  }
  if (req.method !== "POST") return new Response("ok");
  let update: { message?: { chat?: { id?: number; type?: string }; text?: string } };
  try { update = await req.json(); } catch { return new Response("ok"); }
  const chatId = update.message?.chat?.id;
  const text = (update.message?.text ?? "").trim();
  const token = Deno.env.get("ALERT_TELEGRAM_BOT_TOKEN");
  if (!chatId || !token || update.message?.chat?.type !== "private") return new Response("ok");

  const m = text.match(/^\/start\s+([A-Za-z0-9]{8})$/);
  if (!m) {
    await reply(token, chatId, "Open your dashboard, tap Connect Telegram, and send the code shown there.");
    return new Response("ok");
  }
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data, error } = await db.rpc("system_telegram_link", { p_code: m[1], p_chat_id: chatId });
  await reply(token, chatId, !error && data === true
    ? "Connected. You will get a message here for every settled payment."
    : "That code is wrong or expired. Get a new one from your dashboard.");
  return new Response("ok");
});
