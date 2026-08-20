import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GITHUB_TOKEN = Deno.env.get("GITHUB_TOKEN")!;
const GITHUB_OWNER = Deno.env.get("GITHUB_OWNER")!;
const GITHUB_REPO = Deno.env.get("GITHUB_REPO")!;

const supabaseAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

serve(async (req) => {
  const authHeader = req.headers.get("x-cron-secret");
  if (authHeader !== Deno.env.get("CRON_SECRET")) {
    return new Response("Unauthorized", { status: 401 });
  }

  // Pull EVERY record — this is a full ledger snapshot, not just today's.
  // Small dataset for now; if it grows large later, switch to date-ranged exports.
  const [payments, withdrawals, links, profiles, dailyStats] = await Promise.all([
    supabaseAdmin.from("payments").select("*").order("created_at", { ascending: true }),
    supabaseAdmin.from("withdrawals").select("*").order("requested_at", { ascending: true }),
    supabaseAdmin.from("payment_links").select("*"),
    supabaseAdmin.from("profiles").select("id, email, display_name, role, withdrawal_fee_percent, created_at"),
    supabaseAdmin.from("daily_stats").select("*").order("stat_date", { ascending: true }),
  ]);

  const snapshot = {
    generated_at: new Date().toISOString(),
    payments: payments.data ?? [],
    withdrawals: withdrawals.data ?? [],
    payment_links: links.data ?? [],
    profiles: profiles.data ?? [],
    daily_stats: dailyStats.data ?? [],
  };

  const jsonContent = JSON.stringify(snapshot, null, 2);
  const today = new Date().toISOString().slice(0, 10);
  const path = `ledger-backups/${today}.json`;

  // GitHub Contents API — create or update the file
  const apiUrl = `https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/contents/${path}`;

  // Check if a file already exists today (to get its sha for update, else create fresh)
  let sha: string | undefined;
  const existing = await fetch(apiUrl, {
    headers: { "Authorization": `token ${GITHUB_TOKEN}`, "Accept": "application/vnd.github+json" },
  });
  if (existing.ok) {
    const existingData = await existing.json();
    sha = existingData.sha;
  }

  const commitRes = await fetch(apiUrl, {
    method: "PUT",
    headers: {
      "Authorization": `token ${GITHUB_TOKEN}`,
      "Accept": "application/vnd.github+json",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      message: `Ledger backup — ${today}`,
      content: btoa(unescape(encodeURIComponent(jsonContent))),
      ...(sha ? { sha } : {}),
    }),
  });

  if (!commitRes.ok) {
    const errText = await commitRes.text();
    console.error("GitHub commit failed:", errText);
    return new Response(JSON.stringify({ error: "Backup failed", detail: errText }), { status: 500 });
  }

  return new Response(JSON.stringify({
    status: "backed up",
    path,
    payments: snapshot.payments.length,
    withdrawals: snapshot.withdrawals.length,
  }), { status: 200, headers: { "Content-Type": "application/json" } });
});
