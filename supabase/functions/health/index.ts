import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cronAuthorized } from "../_shared/cron.ts";

/**
* Boltpay — health monitor
*
* Answers one question: is the money pipeline actually alive right now?
*
* Everything else in this system reports on things that already
* happened. Nothing notices when something STOPS happening — and the
* failures that matter most here are silent ones:
*
*   * watcher stopped      → Lightning invoices are paid but never
*                            settled into the ledger. Creators are not
*                            credited. The site looks completely normal.
*   * cron stopped         → backups and the daily
*                            archive all quietly stop.
*   * withdrawals stuck    → a creator asked for money days ago and
*                            nobody noticed the request.
*
* Each check has a threshold chosen to be quiet when things are fine.
* An alert that fires on a normal Tuesday is an alert nobody reads.
*
* Read-only. It changes nothing.
*/

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

function sendAlert(message: string) {
  const text = `🚨 Boltpay health: ${message}`;
  const webhook = Deno.env.get("ALERT_WEBHOOK_URL");
  if (webhook) {
    fetch(webhook, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ content: text }),
    }).catch((e) => console.error("Alert delivery failed:", e));
  }
  const tgToken = Deno.env.get("ALERT_TELEGRAM_BOT_TOKEN");
  const tgChat = Deno.env.get("ALERT_TELEGRAM_CHAT_ID");
  if (tgToken && tgChat) {
    fetch(`https://api.telegram.org/bot${tgToken}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: tgChat, text }),
    }).catch((e) => console.error("Telegram alert delivery failed:", e));
  }
}

const MIN = 60 * 1000;
const HOUR = 60 * MIN;

type Check = {
  name: string;
  ok: boolean;
  detail: string;
  /** false = worth waking someone; true = informational only */
  informational?: boolean;
};

Deno.serve(async (req) => {
  const url = new URL(req.url);
  // Env CRON_SECRET or Vault boltpay_cron_secret; constant-time, fails closed.
  if (!(await cronAuthorized(req, supabase))) return new Response("Unauthorized", { status: 401 });

  // Alerts are suppressed for manual runs unless explicitly asked for, so
  // checking the dashboard by hand does not spam the alert channel.
  const alertsOn = url.searchParams.get("alert") !== "0";

  const checks: Check[] = [];
  const now = Date.now();

  // ---------- 1. Is lnd-watcher settling invoices? ----------
  // lnd-watcher (every minute) settles or expires each open invoice. If an
  // LND invoice is still open well past its expiry, the watcher is down.
  {
    const tenMinAgo = new Date(now - 10 * MIN).toISOString();
    const dayAgoIso = new Date(now - 24 * HOUR).toISOString();
    const { count: overdue, error: lndErr } = await supabase
      .from("payments")
      .select("*", { count: "exact", head: true })
      .eq("backend", "lnd")
      .in("status", ["new", "pending"])
      .lt("expires_at", tenMinAgo)
      .gte("expires_at", dayAgoIso);
    checks.push({
      name: "lnd_watcher",
      ok: !lndErr && (overdue ?? 0) === 0,
      detail: lndErr
        ? `could not query LND invoices: ${lndErr.message}`
        : (overdue ?? 0) === 0
        ? "no LND invoice left open past expiry"
        : `${overdue} LND invoice(s) still open >10m past expiry — lnd-watcher may be down`,
    });
  }

  // ---------- 3. Is cron still running? ----------
  // Checked by output rather than by asking pg_cron: a job that runs and
  // fails every night would still look scheduled.
  const { data: lastStat } = await supabase
    .from("daily_stats")
    .select("computed_at")
    .order("computed_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  const statAge = lastStat?.computed_at ? now - new Date(lastStat.computed_at).getTime() : Infinity;
  checks.push({
    name: "cron",
    ok: statAge < 36 * HOUR,
    detail: lastStat?.computed_at
      ? `daily-report last wrote ${Math.round(statAge / HOUR)}h ago`
      : "daily_stats has never been written",
  });

  // ---------- 4. Withdrawals waiting too long ----------
  const dayAgo = new Date(now - 24 * HOUR).toISOString();
  const { data: stuck } = await supabase
    .from("withdrawals")
    .select("id, amount_requested, requested_at")
    .in("status", ["pending", "approved"])
    .lt("requested_at", dayAgo)
    .order("requested_at", { ascending: true });

  const stuckCount = (stuck ?? []).length;
  checks.push({
    name: "withdrawals",
    ok: stuckCount === 0,
    detail: stuckCount === 0
      ? "nothing waiting over 24h"
      : `${stuckCount} withdrawal(s) pending over 24h, oldest from ${stuck![0].requested_at}`,
  });

  // ---------- 4b. Withdrawals stuck mid-payout ----------
  // A row should never sit at "processing" for long. Past 15 minutes a
  // human has to check it and confirm paid or void it.
  const fifteenMinAgo = new Date(now - 15 * MIN).toISOString();
  const { data: stuckProcessing } = await supabase
    .from("withdrawals")
    .select("id, amount_requested, requested_at")
    .eq("status", "processing")
    .lt("requested_at", fifteenMinAgo)
    .order("requested_at", { ascending: true });

  const stuckProcessingCount = (stuckProcessing ?? []).length;
  checks.push({
    name: "withdrawals_processing",
    ok: stuckProcessingCount === 0,
    detail: stuckProcessingCount === 0
      ? "nothing stuck mid-payout"
      : `${stuckProcessingCount} withdrawal(s) stuck at "processing" over 15m — check it by hand, oldest from ${stuckProcessing![0].requested_at}`,
  });

  const failing = checks.filter((c) => !c.ok && !c.informational);
  const healthy = failing.length === 0;

  if (!healthy && alertsOn) {
    sendAlert(failing.map((c) => `${c.name}: ${c.detail}`).join("\n"));
  }

  return new Response(
    JSON.stringify({ healthy, checkedAt: new Date().toISOString(), checks }, null, 2),
    {
      // 503 when unhealthy so an uptime monitor pointed at this URL can
      // page on the status code alone, without parsing the body.
      status: healthy ? 200 : 503,
      headers: { "Content-Type": "application/json" },
    },
  );
});
