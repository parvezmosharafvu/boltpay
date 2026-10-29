// LND checkout: cron safety net (planned: every minute via pg_cron with
// x-cron-secret, like daily-report). Looks up every open LND invoice and
// settles or expires it through the same idempotent SQL functions the
// status endpoint uses. Fails closed without CRON_SECRET; does nothing
// without the LND secrets. Scheduled every minute by pg_cron job "boltpay-lnd-watcher".
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cronAuthorized } from "../_shared/cron.ts";
import { LndClient, lndConfig } from "../_shared/lnd.ts";
import { syncLndPayment } from "../_shared/lnd_settle.ts";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(async (req) => {
  if (!(await cronAuthorized(req, db))) {
    return new Response("Unauthorized", { status: 401 });
  }
  const cfg = await lndConfig(db);
  if (!cfg) return Response.json({ skipped: "LND not configured" });
  const lnd = new LndClient(cfg);

  // Open LND rows, including ones up to a day past expiry, in case the
  // payment landed just before the deadline and nobody was polling.
  const { data: rows, error } = await db
    .from("payments")
    .select("id, user_id, status, lnd_r_hash, expires_at")
    .eq("backend", "lnd")
    .in("status", ["new", "pending"])
    .gte("expires_at", new Date(Date.now() - 86_400_000).toISOString())
    .order("created_at", { ascending: true })
    .limit(200);
  if (error) return new Response(`query failed: ${error.message}`, { status: 500 });

  const tally: Record<string, number> = { settled: 0, expired: 0, open: 0, unchanged: 0, errors: 0 };
  for (const row of rows ?? []) {
    try {
      tally[await syncLndPayment(db, lnd, row)]++;
    } catch (e) {
      tally.errors++;
      console.error("watcher:", row.id, (e as Error).message);
    }
  }
  return Response.json({ checked: rows?.length ?? 0, ...tally }, { status: tally.errors ? 207 : 200 });
});
