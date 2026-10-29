# Progress checklist

Ticked = done and either **verified** (checked by a command or API call) or **confirmed** (reported by the owner).
Task IDs refer to [work-plan.md](work-plan.md). Last updated: Thu 29 Oct 2026.

## 1. Platform setup (D-01, D-02, X-02, X-04)

### Supabase
- [x] Prod project `mystique-prod` (`ibhenicubyvvotlkefrh`), Singapore, healthy (verified)
- [x] Staging project `mystique-staging` (`pdiwvazaqwtjmkrhilbn`), Singapore, healthy (verified)
- [x] Access tokens work; each account sees only its own project (verified, both)
- [x] Staging DB password works; CLI linked to **staging only** (verified)
- [ ] Prod DB password tested (on the first CI deploy)
- [ ] Org MFA enabled on both Supabase accounts
- [ ] Auth URLs: site URL + redirect allowlist (staging, prod)
- [ ] Auth SMTP pointed at Gmail (staging, prod)
- [ ] Auth hardening pushed: 10-min OTP, TOTP MFA, rate limits (staging, prod)
- [ ] Auth CAPTCHA (Turnstile) switched on, only after the login page works on staging

### Cloudflare
- [x] Prod Pages project `mystique-26` → https://mystique-26.pages.dev (verified via API)
- [x] Staging Pages project → https://mystique-staging.pages.dev (confirmed)
- [x] Prod API token, *Cloudflare Pages: Edit* only; rolled after exposure in chat (verified)
- [x] Prod Turnstile widget, hostname `mystique-26.pages.dev` only (secret verified)
- [x] Prod preview deployments restricted (confirmed)
- [x] Staging Cloudflare account (`9881…`), token reads `mystique-staging` → `mystique-staging.pages.dev` (verified)
- [x] Staging Turnstile widget; secret valid (verified)
- [ ] Staging preview deployments restricted, the other devs' emails allowed
- [ ] 2FA on both Cloudflare accounts

### Mail (Gmail SMTP; replaces the domain plan in X-02/D-02)
- [x] Dedicated prod sender `mystique26.tickets@gmail.com`, App Password, login OK on ports 465 and 587 (verified, nothing sent)
- [x] Staging SMTP login OK (verified). **Note:** it uses the prod sender *and* prod App Password, so it shares the ~500/day limit and gets revoked together with prod
- [ ] Staging gets its own sender (`dewminathedeveloper@gmail.com`) or at least its own App Password
- [ ] Test email sent; lands in the inbox, not spam
- [ ] Edge Function → `smtp.gmail.com:465` reachability test (decides Gmail vs Brevo API for order emails)

### GitHub
- [x] Repo `BMMV-21-Batch/Mystique` made **public** (free plan has no protection for private repos). History scanned: no secrets ever committed (verified)
- [x] Secret scanning + push protection, Dependabot alerts on (verified)
- [x] Actions: workflow token read-only by default; fork-PR workflows need approval for all outside contributors (verified)
- [x] Initial structure committed and pushed to `main` (`00e7701`, no `.env` files in the tree; verified)
- [x] Branches `staging` and `prod` created from `main` and pushed (both at `00e7701`; verified)
- [x] Environment `production`: deploys only from `prod`, your approval required (verified)
- [x] Environment `staging`: deploys only from `staging` (verified)
- [x] Prod secrets (5) and variables (6) loaded into `production` (verified)
- [x] Staging secrets (5) and variables (6) loaded into `staging` (verified)
- [x] Branch protection: `prod` PR + 1 approval; `staging` PR; `main` no force-push or delete; admins can bypass (verified)
- [x] Third-party actions pinned to commit SHAs; gitleaks binary checksum-verified (verified)
- [x] `undici` patched to 7.30.1 via override (8 advisories in wrangler's deps); `pnpm audit` clean (verified)
- [x] First CI run green on GitHub (runs 40880729184, 40881235247; verified)
- [x] Staging smoke deploy green: CI linked `mystique-staging` with the staging secrets (run 40881497786; verified)
- [ ] Prod smoke deploy with approval (first test of the prod DB password)
- [x] Flow (decided 29 Oct): feature → PR into `staging` (CI) → merge deploys staging → PR `staging` → `prod` (no CI) → merge + approval deploys prod. `main` is unused
- [x] `staging` requires the 3 CI checks, and the branch must be up to date before merging (verified)
- [x] Default branch is `staging`, so new PRs and clones start from staging (verified)
- [x] Sole approver for prod: `production` environment reviewer = `dewminawijekoon`; `prod` requires code-owner review (verified)
- [ ] `.github/CODEOWNERS` committed and merged into `prod` (code-owner review only takes effect once the file is on `prod`)
- [ ] Add the other 3 devs as collaborators (write access) when they're ready

### Local tooling (A-01)
- [x] pnpm, Supabase CLI 2.121.0, wrangler 4.151.0 pinned; 14-day release-age guard (verified)
- [x] `supabase init` + `config.toml` (OTP, MFA, 2 MiB uploads)
- [x] Folder structure + READMEs (spec §3.3)
- [x] `supabase start` runs locally: full stack, 12 containers healthy; Auth, Studio and the email inbox respond (verified)

### Decisions recorded
- [x] Region: Singapore (51 ms vs Mumbai 94 ms from Colombo)
- [x] Site on `*.pages.dev`; no custom domain
- [x] Mail via dedicated Gmail accounts, not a sending domain
- [x] Spec defects SD-1, 2, 5, 7 resolved with the owner (work plan §3)
- [ ] Remaining §20 open questions answered (X-03)

## 2. R1 tasks (due Mon 2 Nov)

### Pre-flight
- [ ] X-01 Freeze interfaces (RPCs, Edge contracts, routes, error codes)
- [ ] X-02 Mail provider + region decision
- [ ] X-03 Owners for §20 open questions
- [ ] X-04 Access governance (MFA, members, private repo, branch protection)
- [ ] X-05 Spec defects triaged

### Stream A: Data & logic
- [x] A-01 Local stack: init + full `supabase start` (verified)
- [x] A-02 Migration 001 extensions/types: `db reset` applies it (verified)
- [x] A-03 Migration 002 tables: RLS on + API grants revoked on every table until 006; anon gets 401 on every table (verified)
- [x] A-04 Migration 003 helpers + TRUNCATE guard: QR secret generated in-DB; pgTAP `003_foundation` 24/24, incl. T12 UPDATE/DELETE/TRUNCATE (verified)
- [x] Staging: 001–003 applied by the deploy after merge; pg_cron accepted without a dashboard step (verified)
- [x] A-05 Migration 004 user functions + `set_my_locale` (SD-11), constraint errors → `VALIDATION` and payment ref ≥ 4 chars (SD-14), `ACCOUNT_SUSPENDED` on every write (SD-5); not API-callable until 006 (anon gets 401); pgTAP `004_user_functions` 41/41 (verified)
- [x] A-06 Migration 005 admin/dev functions: reject-and-release (SD-1), `admin_set_status` (SD-5), `admin_users_v` fix (SD-10), manifest VOLATILE (SD-12), strict UUID (SD-13), `holder_names` (SD-17), config fields + null clears URL + first-setup insert (SD-19), top uploaders in health (SD-2); pgTAP `005_admin_dev_functions` 71/71, 136 total (verified)
- [ ] A-07 Migration 006 RLS/grants (note: grants must use the new `reject_order(uuid,text,text,boolean)` and add `admin_set_status`, `set_my_locale`)
- [ ] A-08 Migration 007 storage (10 uploads/day)
- [ ] A-09 Migration 008 cron
- [ ] A-10 seed.sql
- [ ] A-11 pgTAP role helpers
- [ ] A-12 pgTAP T4–T6, T8–T10, T12
- [ ] A-13 T11 RLS matrix
- [ ] A-14 T13 audit
- [ ] A-15 Concurrency T1/T2/T3/T7
- [ ] A-16 CI security queries
- [ ] A-17 SD-1/2/5 tests

### Stream B: User flow
- [ ] B-01 Web scaffold
- [ ] B-02 Landing
- [ ] B-03 OTP login + Turnstile
- [ ] B-04 Auth guard + profile
- [ ] B-05 Buy wizard
- [ ] B-06 Receipt compress + upload
- [ ] B-07 Edge `_shared` hardening
- [ ] B-08 `submit-order`
- [ ] B-09 Confirmation page
- [ ] B-10 Orders + tracker + QR
- [ ] B-11 Ticket page
- [ ] B-12 `resubmit-order` + cancel

### Stream C: Admin & dev
- [ ] C-01 Admin shell + MFA
- [ ] C-02 Server table component
- [ ] C-03 Orders list
- [ ] C-04 Review screen
- [ ] C-05 Users list + suspend
- [ ] C-06 Basic analytics
- [ ] C-07 `/dev/admins`
- [ ] C-08 `/dev/audit`
- [ ] C-09 `/dev/health`
- [ ] C-10 `/dev/config`
- [ ] C-11 Reconciliation CSV (P1)

### Stream D: Platform, i18n, notifications
- [ ] D-01 Platform setup (in progress: see §1)
- [ ] D-02 Auth + mail (in progress: see §1)
- [ ] D-03 CI pipeline (in progress: `ci.yml` + `deploy.yml` written; actionlint, gitleaks, audit and db reset pass locally. Pending: first GitHub run, staging/prod smoke deploys, required status checks)
- [ ] D-04 i18n framework
- [ ] D-05 Sinhala font subset
- [ ] D-06 Formatters + Zod schemas
- [ ] D-07 Bilingual OTP template
- [ ] D-08 Mail templates
- [ ] D-09 `send-notifications`
- [ ] D-10 `health` + UptimeRobot
- [ ] D-11 Sentry
- [ ] D-12 CSP headers
- [ ] D-13 PWA
- [ ] D-14 Backups + restore test
- [ ] D-15 Sinhala review + privacy notice
- [ ] D-16 `quotas.md`

### QA & release
- [ ] Q-01 Playwright E2E
- [ ] Q-02 k6 load test
- [ ] Q-03 Security release gate
- [ ] Q-04 Localisation checklist
- [ ] Q-05 Dry run (Sun 1 Nov)
- [ ] Q-06 Prod release (Mon 2 Nov)
