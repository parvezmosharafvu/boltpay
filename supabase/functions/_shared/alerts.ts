// Settled-payment alert for the LND path. Same channels, env vars and
// ALERT_ON_SETTLED switch as btcpay-webhook's sendSettledAlert, and the
// same hide_small_payments suppression (should_suppress_payment_alert).
// btcpay-webhook keeps its own copy untouched. Best-effort: never throws,
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
  for (const r of res) if (r.status === "rejected") console.error("settled-alert delivery failed");
  return sends.length;
}

/** Look up amount + slug for a just-settled LND payment and alert. */
export async function notifyLndSettled(db: SupabaseClient, paymentId: string): Promise<void> {
  try {
    const { data: p } = await db.from("payments")
      .select("amount_settled, payment_link_id, user_id").eq("id", paymentId).maybeSingle();
    if (!p) return;
    const amount = Number(p.amount_settled ?? 0);
    const { data: suppress, error } = await db.rpc("should_suppress_payment_alert", { p_amount: amount });
    if (!error && suppress === true) return; // fails open, like btcpay-webhook
    let slug = "unknown-link";
    if (p.payment_link_id) {
      const { data: l } = await db.from("payment_links").select("slug").eq("id", p.payment_link_id).maybeSingle();
      slug = l?.slug ?? slug;
    }
    await sendSettledAlert(settledAlertText(amount, slug, paymentId));
    await notifyCreatorTelegram(db, p.user_id, `✅ Payment received: $${amount.toFixed(2)} via /${slug}`);
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
