# Canonical Domain Consolidation — Read-Only Audit and Safe Plan

Date: 2026-10-18
Repository: parvezmosharafvu/boltpay
Status: Planning and read-only audit only. No production DNS, Worker, database, payment, or webhook changes were made.

## Goal

Use the existing payment-link hostname `cpay-cash.app` as the single canonical host for both the Boltpay website and payment links, while preserving all existing payment slugs, invoices, link previews, and BTCPay webhook behavior.

## Confirmed read-only findings

- GitHub `main` contains the website under `public/`, including `index.html`, `404.html`, `login.html`, `register.html`, `dashboard.html`, and `admin.html`.
- `public/404.html` is intentionally the payment-slug fallback. Hosting must continue to serve it for unmatched single-segment payment slugs.
- `worker/og-preview-worker.js` handles root routing, app-only path redirects, invoice creation proxying at `/api/create-invoice`, crawler OG metadata for payment slugs, and generated OG images.
- `worker/wrangler.jsonc` deliberately does not define routes; the repository expects route bindings to be managed in Cloudflare.
- Cloudflare route read returned `cpay-cash.app/* -> boltpay-og-preview` (route ID `c311ac53380a47fa85c8fcaf879fd5f2`).
- Cloudflare Worker Domain read returned an enabled production custom domain `cpay-cash.app -> boltpay` (domain ID `4b429a23f3fc6a50fbc83ba9d802d4412832901a`).
- Therefore, a Worker route and a Worker custom domain are both configured for the same hostname. Do not assume the route is harmless or that either Worker owns every request; verify real request behavior and precedence before changing either binding.
- Cloudflare's Worker script metadata showed `boltpay` modified on 2026-10-18, while its newest listed deployment is dated 2026-09-18. The `boltpay-og-preview` script metadata showed a modification on 2026-10-09, while its newest listed deployment is dated 2026-09-13. Metadata modification timestamps are not proof that a new version is serving production.
- The route and custom domain configuration should be treated as a potential ownership/routing conflict until tested. The DNS record for `cpay-cash.app` is Cloudflare-managed, proxied, and read-only as a Worker custom-domain record; do not try to edit or replace it as ordinary DNS.
- A previous live browser check observed `https://cpay-cash.app/` redirecting to `https://usa-cash.app/`.
- Both `worker/og-preview-worker.js` and `public/index.html` implement domain-root redirect decisions using `site_domains` fields `purpose`, `is_primary_site`, and `is_active`. The Worker redirects only when the current domain is registered as `purpose='payment'` and it finds another primary/site/both domain. The homepage also contains a browser-side redirect implementation.
- The browser-side redirect in `public/index.html` currently calls `window.location.replace(`{{https://${primary.hostname}}}/`)`. The extra braces are a concrete code defect: it does not produce the intended `https://hostname/` URL. Fix only in a reviewed branch change and add a regression test.
- The connected Supabase account currently lists only the project `cpay` (ref `riumaeihemgznvgattoc`). That is not the Boltpay project referenced by the Worker (`ohwzmxwsphsfzudmlins`). No SQL was run against the unrelated CPAY project. Boltpay `site_domains` rows remain unverified because the correct project is not available in the connected project list.
- Keep Boltpay and CPAY separate: do not inspect or modify CPAY's database as a substitute for Boltpay access.

## Target URL behavior

- `https://cpay-cash.app/` -> Boltpay homepage, without redirecting to another hostname.
- `/login` and `/login.html` -> login page.
- `/register` and `/register.html` -> registration page.
- `/dashboard` and `/dashboard.html` -> dashboard, still protected by existing auth and database policies.
- `/admin` and `/admin.html` -> admin UI, still protected by existing authorization.
- `/<existing-payment-slug>` -> the same payment page as before.
- `/invoice-boltpay-v2.html?... ` -> invoice/payment flow unchanged.
- `POST /api/create-invoice` -> existing Supabase function via Worker proxy, unchanged.
- `/og-image/<slug>.png` and crawler requests for payment slugs -> preview image/metadata from `cpay-cash.app`.
- Unknown/invalid slugs -> existing not-found behavior; never silently rewrite them to the homepage.

## Proposed implementation (not yet applied)

### Phase 1 — Resolve ownership and configuration

1. Identify the correct Boltpay Supabase project and obtain read-only access.
2. Read the active `site_domains` rows for `cpay-cash.app` and `usa-cash.app`, including `hostname`, `purpose`, `is_primary_site`, and `is_active`.
3. Confirm which Worker serves requests for the apex hostname and whether the custom domain and route overlap intentionally.
4. Compare the active Cloudflare Worker version/source with repository `main`; do not deploy until drift is understood.
5. Confirm host and origin settings used by authentication redirects and email links.

### Phase 2 — Minimal code change in a separate branch

1. Make root behavior explicit for the canonical domain so it serves the website instead of redirecting away.
2. Keep old payment slugs resolving through the current `404.html` fallback.
3. Remove duplicated/conflicting browser-side root redirect behavior, or make it consistent with the Worker’s canonical-domain rule.
4. Correct the malformed URL template and add unit/static tests.
5. Keep invoice proxy, webhook code, payment creation, settlement, balances, and payout logic out of scope.

Do not choose a final routing change until Phase 1 resolves which Worker actually owns requests. A code-only fix cannot compensate for the wrong Worker receiving the request.

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

- The correct Boltpay Supabase project is not available in the connected Supabase project list; database inspection is blocked.
- Active production Worker ownership/version and custom-domain/route precedence must be verified.
- No production change is authorized by this document.
- Do not change DNS, Cloudflare Worker bindings/deployments, Supabase rows, BTCPay settings, payment flows, or webhook settings until the plan and diff are reviewed and production change is explicitly approved.
