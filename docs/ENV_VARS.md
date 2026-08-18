# Environment Variables Checklist

No real secret values are stored anywhere in this repository.
Fill these in directly on each platform's dashboard.

## Supabase Edge Function Secrets
(Dashboard → Edge Functions → btcpay-webhook → Secrets)

- [ ] `SUPABASE_URL`
- [ ] `SUPABASE_ANON_KEY`
- [ ] `SUPABASE_SERVICE_ROLE_KEY`
- [ ] `BTCPAY_WEBHOOK_SECRET` — from BTCPay Server → Store → Webhooks
- [ ] `BTCPAY_URL` — e.g. https://your-btcpay-server.com
- [ ] `BTCPAY_API_KEY` — store API key with payout permission
- [ ] `BTCPAY_STORE_ID`

## public/config.js (client-facing — safe to commit, but kept out via .gitignore for cleanliness)

- [ ] `SUPABASE_URL`
- [ ] anon key (the `SUPABASE_ANON_KEY` constant inside config.js)

Copy `public/config.example.js` to `public/config.js` and fill these two in.

## Cloudflare Worker

`worker/og-preview-worker.js` currently has `SUPABASE_URL` and the anon key
hardcoded near the top of the file (these are the same public values as
config.js — safe to keep inline, or move to Worker environment variables
under Settings → Variables if you prefer).
