# Boltpay — Deployment Checklist

## 1. Supabase

- [ ] Create a new Supabase Pro project
- [ ] Run migrations in order from `supabase/migrations/`:
      0001 → 0002 → 0003 → 0004 → 0005 → 0006 → 0007
      (SQL Editor → paste each file's contents → Run, one at a time)
- [ ] Verify with the checks below (see "Verification queries")
- [ ] Deploy the Edge Function:
      `supabase functions deploy btcpay-webhook --no-verify-jwt`
- [ ] Add all secrets listed in `docs/ENV_VARS.md`
- [ ] Create your own account via the app once it's live, then in SQL Editor:
      `update profiles set role = 'admin' where email = 'you@example.com';`

## 2. BTCPay Server

- [ ] Create a Store, connect a Lightning node
- [ ] Add a webhook: URL = `https://YOUR-PROJECT.supabase.co/functions/v1/btcpay-webhook`,
      secret = same value as `BTCPAY_WEBHOOK_SECRET`
- [ ] Enable the Payout Processor plugin (needed for the automated
      Binance/Lightning payout path in the admin panel)
- [ ] Set invoice expiration to 60 minutes

## 3. Frontend hosting (GitHub + Cloudflare Pages, or GitHub Pages)

- [ ] Push this repo to a fresh GitHub repository
- [ ] Copy `public/config.example.js` to `public/config.js`, fill in your
      Supabase URL and anon key
- [ ] Pick ONE of the four dashboard themes in `public/` to use as
      `dashboard.html` (rename or point your router at it) — the other
      three are kept as alternates
- [ ] Point your host at the `public/` folder as the site root
- [ ] Add a `CNAME` file inside `public/` containing your domain if using
      GitHub Pages

## 4. Cloudflare

- [ ] Confirm your domain's nameservers point to Cloudflare (Websites list
      shows it as "Active")
- [ ] Deploy `worker/og-preview-worker.js` (dashboard Quick Edit or
      `wrangler deploy` from a machine that has Node/npm)
- [ ] Add the route: `yourdomain.com/u/*` → the worker
      (Worker → Settings → Triggers → Add route)
- [ ] SSL/TLS mode = Full (strict)

## 5. End-to-end test

- [ ] Register a test account, log in, create a payment link
- [ ] Send a small real (or BTCPay testnet) Lightning payment to a
      generated invoice
- [ ] Confirm the invoice page updates live via Realtime (no manual refresh)
- [ ] Submit a withdrawal request as the test user
- [ ] In the admin panel: approve/reject a pending request, and mark a
      bKash/Nagad request paid manually
- [ ] Paste a payment link into WhatsApp and confirm the link preview
      (OG title/description) renders correctly

## Still missing from this repo (not yet built)

- Everything in the original checklist is now covered by files in
  `public/` and `supabase/migrations/`. Nothing structural is missing —
  remaining work is picking one dashboard theme, filling in real config
  values, and running through the checklist above.

## Verification queries (paste into SQL Editor after running migrations)

```sql
-- Tables + columns
select table_name, column_name, data_type
from information_schema.columns
where table_schema = 'public'
order by table_name, ordinal_position;

-- RLS enabled on every table
select relname, relrowsecurity
from pg_class
where relname in ('profiles','payment_links','payments','withdrawals','app_settings','daily_stats');

-- Policies
select tablename, policyname, cmd from pg_policies where schemaname = 'public';

-- Functions
select proname, prosecdef from pg_proc
where proname in ('is_admin','request_withdrawal','get_invoice_public','get_link_preview','admin_global_stats')
  and pronamespace = 'public'::regnamespace;

-- payments.method constraint (should show CHECK (method = 'lightning'))
select conname, pg_get_constraintdef(oid)
from pg_constraint where conrelid = 'public.payments'::regclass and contype = 'c';

-- Realtime publication includes payments
select schemaname, tablename from pg_publication_tables where pubname = 'supabase_realtime';

-- request_withdrawal must NOT be executable by anon
select grantee, privilege_type from information_schema.routine_privileges
where routine_name = 'request_withdrawal';
```
