# Canonical Domain Consolidation — Read-Only Audit and Safe Plan

Date: 2026-10-18
Repository: parvezmosharafvu/boltpay
Status: Planning only. No production DNS, Worker, database, payment, or webhook changes were made.

## Goal

Use the existing payment-link hostname `cpay-cash.app` as the single canonical host for both the Boltpay website and payment links, while preserving all existing payment slugs, invoices, link previews, and BTCPay webhook behavior.

## Read-only findings

- GitHub `main` currently has the website under `public/`, including `index.html`, `404.html`, `login.html`, `register.html`, `dashboard.html`, and `admin.html`.
- `public/404.html` is intentionally the payment-slug fallback. Hosting must continue to serve it for unmatched single-segment payment slugs.
- `worker/og-preview-worker.js` handles root routing, app-only path redirects, invoice creation proxying at `/api/create-invoice`, crawler OG metadata for payment slugs, and generated OG images.
- `worker/wrangler.jsonc` deliberately does not define routes; the repository expects route bindings to be managed in Cloudflare.
- Cloudflare read-only route query returned `cpay-cash.app/* -> boltpay-og-preview`.
- Cloudflare read-only Worker Domain query returned `cpay-cash.app -> boltpay` as an enabled production custom domain.
- Cloudflare deployment metadata for `boltpay` showed its latest listed deployment on 2026-09-18. The `boltpay-og-preview` deployment list showed its latest listed deployment on 2026-09-13. Verify the active version/content before any deployment.
- Live browser check previously observed `https://cpay-cash.app/` redirecting to `https://usa-cash.app/`.
- Both `worker/og-preview-worker.js` and `public/index.html` implement domain-root redirect decisions using `site_domains` fields `purpose`, `is_primary_site`, and `is_active`. The worker redirects only when the current domain is marked `purpose='payment'` and it finds another primary/site/both domain. The homepage also contains a browser-side redirect implementation.
- The current connected Supabase project list did not identify the Boltpay project whose URL is referenced in the repo. Do not run queries against another project by assumption.
- The root redirect template in `public/index.html` contains suspicious extra braces around the HTTPS URL in `window.location.replace(...)`; correct it only in a reviewed code change, with a regression test.

## Target URL behavior

- `https://cpay-cash.app/` -> Boltpay homepage, without redirecting to another hostname.
- `/login` and `/login.html` -> login page.
- `/register` and `/register.html` -> registration page.
- `/dashboard` and `/dashboard.html` -> dashboard, still protected by existing auth and database policies.
- `/admin` and `/admin.html` -> admin UI, still protected by existing authorization.
- `/<existing-payment-slug>` -> the same payment page as before.
- `/invoice-boltpay-v2.html?... ` -> invoice/payment flow unchanged.
- `/api/create-invoice` POST -> existing Supabase function via Worker proxy, unchanged.
- `/og-image/<slug>.png` and crawler requests for payment slugs -> preview image/metadata from `cpay-cash.app`.
- Unknown/invalid slugs -> existing not-found behavior; never silently rewrite them to the homepage.

## Proposed implementation (not yet applied)

### Phase 1 — Resolve ownership and configuration
1. Identify the correct Boltpay Supabase project and obtain read-only access.
2. Read the active `site_domains` rows for `cpay-cash.app` and `usa-cash.app`, including `hostname`, `purpose`, `is_primary_site`, and `is_active`.
3. Confirm which Worker serves requests for the apex hostname and whether the custom domain and route overlap intentionally.
4. Compare the active Cloudflare Worker version/source with repository `main`; do not deploy until drift is understood.
5. Confirm host and origin settings used by authentication redirects and email links.

### Phase 2 — Minimal code change in this branch
1. Make root behavior explicit for the canonical domain so it serves the website instead of redirecting away.
2. Keep old payment slugs resolving through the current `404.html` fallback.
3. Remove duplicated/conflicting browser-side root redirect behavior, or make it consistent with the Worker’s canonical-domain rule.
4. Correct the malformed URL template and add unit/static tests.
5. Keep invoice proxy, webhook code, payment creation, settlement, balances, and payout logic out of scope.

### Phase 3 — Tests before release
- Root request in a normal browser and as a crawler.
- Login, registration, dashboard, and admin routes.
- Existing and unknown payment slugs.
- Invoice QR/payment page and query parameters.
- `POST /api/create-invoice` request and response shape.
- OG metadata and image endpoints, including cache misses.
- Authentication redirect allowlists and email confirmation/reset links.
- BTCPay webhook signature verification and duplicate-event idempotency remain unchanged.
- No redirect loop and no cross-domain redirect from the canonical hostname.

### Phase 4 — Release and rollback
1. Review branch diff and CI results.
2. Test on a staging hostname or preview environment first.
3. Export/save current domain registry values and Cloudflare route/domain configuration before any production change.
4. Release only after explicit production approval.
5. Verify root, auth, payment slug, invoice, and crawler flows immediately after release.
6. Roll back by restoring the previous Worker version and prior domain registry values if any critical route or payment test fails.

## Blockers / approval gates

- Boltpay Supabase project is not yet confirmed in the connected Supabase account; database inspection is blocked.
- Active production Worker content/version and custom-domain/route precedence must be verified.
- No production change is authorized by this document.
- Do not change DNS, Cloudflare Worker bindings/deployments, Supabase rows, BTCPay settings, payment flows, or webhook settings until the plan and diff are reviewed and production change is explicitly approved.
