# Boltpay

Lightning Network payment links for freelancers and online shop owners.
Generate a payment link, share it, get paid — withdrawals to bKash,
Nagad, or Binance with an admin-reviewed payout flow.

## Stack

- **Frontend:** Vanilla HTML/CSS/JS + Supabase JS v2 (no build step)
- **Backend:** Supabase — Postgres, Row Level Security, Edge Functions
- **Payments:** BTCPay Server (Lightning Network only)
- **Edge routing:** Cloudflare Worker — renders correct link-preview
  metadata for WhatsApp/Telegram/Facebook when a payment link is shared

## Repo layout

```
public/                          → static site root
  index.html                     → landing page + logged-in redirect
  login.html / register.html     → auth pages
  404.html                       → not-found page
  dashboard-theme{1-4}-*.html    → four creator-dashboard designs, pick one
  invoice-boltpay-v2.html        → customer-facing payment/QR page
  admin.html                     → admin panel (approvals, stats, settings)
  config.example.js              → copy to config.js, fill in your keys

supabase/
  migrations/                    → run in numeric order
  functions/btcpay-webhook/      → BTCPay webhook + admin withdrawal actions

worker/
  og-preview-worker.js           → Cloudflare Worker for OG tags
  wrangler.toml

docs/
  DEPLOYMENT.md                  → full setup checklist
  ENV_VARS.md                    → what secrets go where
```

## Setup

Follow `docs/DEPLOYMENT.md` top to bottom — it's ordered so each step's
dependencies are already in place by the time you reach it.

## Security notes worth knowing before you deploy

- `request_withdrawal` and `admin_global_stats` are only callable by
  authenticated users — verified via `information_schema.routine_privileges`
  during development. Re-check this after any migration changes.
- The Edge Function's `/process-withdrawal` route requires a valid admin
  JWT — it uses the service role key internally, which bypasses RLS
  entirely, so this check has to live in code, not the database.
- `payments.method` is constrained to `'lightning'` only at the database
  level — USDC support was intentionally removed.
- Anon access to `payments` is column-limited (id, amounts, method,
  status, expires_at only) — added specifically so the public invoice
  page can receive Realtime updates without exposing `user_id` or
  internal identifiers.
