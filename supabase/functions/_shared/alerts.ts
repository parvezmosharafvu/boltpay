// Settled-payment alert. Uses the ALERT_ON_SETTLED switch and the
// hide_small_payments suppression (should_suppress_payment_alert).
// Best-effort: never throws,
// a failure only reaches the function log.
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

type Env = (k: string) => string | undefined;

export function settledAlertText(amount: number, slug: string, paymentId: string): string {
  return `✅ Payment settled (Lightning): $${amount.toFixed(2)} via /${slug} (payment ${paymentId.slice(0, 8)})`;
}

export async function sendSettledAlert(
  text: string,
  env: Env = (k) => Deno.env.get(k),
  doFetch: typeof fetch = fetch,
): Promise<number> {
  if ((env("ALERT_ON_SETTLED") ?? "true").toLowerCase() === "false") return 0;
  return await sendOpsAlert(text, env, doFetch);
}

/**
 * Owner/ops alert to the webhook and admin Telegram chat, with no
 * ALERT_ON_SETTLED switch. Best-effort, never throws, never logs the
 * token, chat id or message.
 */
export async function sendOpsAlert(
  text: string,
  env: Env = (k) => Deno.env.get(k),
  doFetch: typeof fetch = fetch,
): Promise<number> {
  const sends: Promise<unknown>[] = [];
  const webhook = env("ALERT_WEBHOOK_URL");
  if (webhook) {
    sends.push(doFetch(webhook, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ content: text }),
    }));
  }
  const tgToken = env("ALERT_TELEGRAM_BOT_TOKEN");
  const tgChat = env("ALERT_TELEGRAM_CHAT_ID");
  if (tgToken && tgChat) {
    sends.push(doFetch(`https://api.telegram.org/bot${tgToken}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: tgChat, text }),
    }));
  }
  const res = await Promise.allSettled(sends);
  for (const r of res) if (r.status === "rejected") console.error("alert delivery failed");
  return sends.length;
}

/**
 * Sensitive withdrawal verification codes go ONLY to the signed-in owner's
 * linked Telegram chat, never to the general ops webhook/group.
 * A successful HTTP status alone is not enough: Telegram must return ok=true.
 * Fail closed if the owner is unlinked, the bot is unconfigured, or delivery
 * is rejected. Never log the message, code, token or chat ID.
 */
export async function sendNodeWithdrawStepup(
  text: string,
  ownerChatId: string | null | undefined,
  env: Env = (k) => Deno.env.get(k),
  doFetch: typeof fetch = fetch,
): Promise<boolean> {
  const token = env("ALERT_TELEGRAM_BOT_TOKEN");
  const chatId = String(ownerChatId ?? "").trim();
  if (!token || !chatId) return false;
  try {
    const response = await doFetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, text }),
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) return false;
    const payload = await response.json();
    return payload?.ok === true;
  } catch {
    return false;
  }
}

/** Look up amount + slug for a just-settled LND payment and alert. */
export async function notifyLndSettled(db: SupabaseClient, paymentId: string): Promise<void> {
  try {
    const { data: p } = await db.from("payments")
      .select("amount_settled, net_usd, buyer_amount, payment_link_id, user_id").eq("id", paymentId).maybeSingle();
    if (!p) return;
    const amount = Number(p.amount_settled ?? 0);
    const { data: suppress, error } = await db.rpc("should_suppress_payment_alert", { p_amount: amount });
    if (!error && suppress === true) return; // fails open
    let slug = "unknown-link";
    let label = slug;
    let pct = 0;
    if (p.payment_link_id) {
      const { data: l } = await db.from("payment_links").select("slug, display_name, cost_percent").eq("id", p.payment_link_id).maybeSingle();
      slug = l?.slug ?? slug;
      label = l?.display_name || slug;
      pct = Number(l?.cost_percent ?? 0);
    }
    await sendSettledAlert(settledAlertText(amount, slug, paymentId));
    await notifyCreatorTelegram(db, p.user_id, creatorPaidText(creatorShownAmount(p.buyer_amount, p.net_usd, amount), label, pct));
  } catch (e) {
    console.error("notifyLndSettled:", (e as Error).message);
  }
}


/** Message the link owner's own Telegram chat, if they connected one. Never throws. */
export async function notifyCreatorTelegram(
  db: SupabaseClient,
  userId: string | null | undefined,
  text: string,
  env: Env = (k) => Deno.env.get(k),
  doFetch: typeof fetch = fetch,
): Promise<boolean> {
  try {
    const token = env("ALERT_TELEGRAM_BOT_TOKEN");
    if (!token || !userId) return false;
    const { data } = await db.from("profiles").select("telegram_chat_id").eq("id", userId).maybeSingle();
    const chat = data?.telegram_chat_id;
    if (!chat) return false;
    const r = await doFetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chat, text }),
    });
    return r.ok;
  } catch {
    console.error("creator telegram delivery failed");
    return false;
  }
}

/** Base link amount (no extra fee, no conversion fee); net/settled only as fallback. Display only. */
export function creatorShownAmount(base: unknown, net: unknown, settled: number): number {
  const b = Number(base ?? 0);
  if (b > 0) return b;
  const n = Number(net ?? NaN);
  return Number.isFinite(n) ? n : settled;
}

/** Creator Telegram text: net amount and "Name 27%" only, no fee breakdown. */
export function creatorPaidText(net: number, label: string, pct = 0): string {
  const tag = pct > 0 ? `${label} ${Number(pct)}%` : label;
  return `✅ Payment received: $${net.toFixed(2)} · ${tag}`;
}
