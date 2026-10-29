# Batch Party Ticketing Platform: Work Plan

| | |
|---|---|
| **Status** | v1.0, for team kick-off on Thu 29 Oct 2026 (evening) |
| **Spec** | [ticketing-architecture.md](ticketing-architecture.md) (Draft v0.1), referred to below as "spec §n" |
| **Ticket sales go live (R1)** | **Mon 2 Nov 2026** |
| **Event (gate go-live, R2)** | **Sat 26 Dec 2026** |
| **Team** | 4 devs working with Claude Code |

---

## How to read this plan

- **Task IDs:**
  - `X` pre-flight
  - `A` data & logic
  - `B` user flow
  - `C` admin & dev
  - `D` platform, i18n & notifications
  - `Q` QA & release
  - `R11` R1.1
  - `G` gate (R2)
  - `R3` close-out
  - `SD` spec defect
- **Refs** point to spec requirement IDs (`U-2`, `A-3`, `N-3`…), spec sections (`§9.1`) and spec defects (`SD-4`).
- **Pri:**
  - `P0` blocks its release.
  - `P0/cutN` is P0 but sits at position N on the cut list.
  - `P1` ships in that release only if time allows.
- **Day** (R1): `Thu` = Thu 29 Oct evening, `Fri`, `Sat`, `Sun`, `Mon` = Mon 2 Nov morning.
- **Done when** is the acceptance check. A task is not done until its check passes on **staging**.
- Security work is spread across all streams, not kept in a separate stream. §6 maps every threat to its control, task and test.

---

## Contents

1. [Releases and capacity](#1-releases-and-capacity)
2. [Pre-flight (Thu evening)](#2-pre-flight-thu-evening)
3. [Spec defects to fix before implementing](#3-spec-defects-to-fix-before-implementing)
4. [R1 Sales: task tables](#4-r1-sales-task-tables)
5. [R1.1, R2 Gate, R3 Close-out](#5-r11-r2-gate-r3-close-out)
6. [Security traceability](#6-security-traceability)
7. [Requirement coverage](#7-requirement-coverage)
8. [Operations during the sales period](#8-operations-during-the-sales-period)

---

## 1. Releases and capacity

| Release | Date | Scope |
|---|---|---|
| **R1 Sales** | Mon 2 Nov | Buy flow, review, email, admin and dev portals, Sinhala and English, **all security hardening**, backups, monitoring |
| **R1.1 Steady state** | 3–15 Nov | Items cut from R1, WhatsApp tracking (A-6), full analytics (A-4), purge function built and tested |
| **R2 Gate** | Code complete Sat 5 Dec · staging drill Sat 12 Dec · freeze Sat 19 Dec | Online scanner, manual lookup, undo, door list, **offline scanner (now P0)**, check-in analytics |
| **R3 Close-out** | Sales close → Sat 2 Jan 2027 | Final reconciliation, data purge (event + 7 days), decommission staging |

The check-in SQL functions (`check_in_ticket`, `scanner_manifest`, `sync_offline_scans`) **ship in R1's migrations** and are tested in R1. That keeps the schema in one place and the tests running early. Only the scanner UI waits for R2.

### 1.1 R1 capacity

We plan on about **12 effective hours per dev per day**. Working around the clock produces the kind of bugs this plan exists to prevent.

| Window | Hours/dev |
|---|---|
| Thu evening | 4 |
| Fri, Sat, Sun | 3 × 12 = 36 |
| Mon morning | 4 |
| **Total** | **44 h/dev → 176 h for 4 devs** |

| Owner | Tasks | Est h |
|---|---|---|
| Dev 1, stream A (also release lead) | X-01, X-05, A-01…A-17, Q-03, Q-06 | 2 + 1 + 35 + 3 + 2.5 = **43.5** |
| Dev 2, stream B | B-01…B-12, Q-01 | 32 + 5 = **37** |
| Dev 3, stream C | C-01…C-11, X-03 | 34 + 0.5 = **34.5** |
| Dev 4, stream D | X-02, X-04, D-01…D-16, Q-02, Q-04 | 1 + 1 + 32 + 1.5 + 2 = **37.5** |
| All | Q-05 dry run | 3 each |

Total ≈ 155.5 h of tasks against 176 h available (88%). Dev 1 is the most loaded. If Dev 1 slips, Dev 3 takes over A-14 and A-16.

### 1.2 R1 cut list (apply in this order if behind on Sat evening)

1. C-06 analytics panels beyond the capacity gauge and the pending-seat alert
2. C-05 user detail page (keep the list)
3. D-13 PWA (manifest and service worker)
4. Q-02 k6 load test (20 users is trivial load; T1/T2 cover correctness)
5. B-12 resubmit UI (keep `resubmit_order` working; the UI falls back to "cancel and buy again")
6. C-11 reconciliation export (the daily checkers can work from the review screen)

**Never cut:**
- RLS, admin MFA, idempotency, the audit log, receipt validation
- **every `Sec` spec defect fix (§3)**, including account suspension and the upload limit
- Sinhala support, backups with a tested restore

---

## 2. Pre-flight (Thu evening)

| ID | Task | Refs | Depends on | Est h | Pri | Day | Done when |
|---|---|---|---|---|---|---|---|
| X-01 | Freeze the interfaces: the RPC signatures (spec §8.1 plus `set_my_locale`, `admin_set_status`, `reject_order(…, p_release)`), the Edge contracts (§9), routes (§12.2) and error codes (App. A plus `ACCOUNT_SUSPENDED`, `UPLOAD_LIMIT`) | §0, §8.1, §9, §12.2 | none | 2 | P0 | Thu | `docs/contracts.md` is merged and every stream owner has approved it |
| X-02 | Choose the mail provider. Compare the **current** free daily and monthly limits of Resend and Brevo, remembering that OTP and transactional mail share one cap over 8 weeks of sales. Buy the domain. Run the region ping test (Mumbai vs Singapore) | R-1, R-3, SD-21 | none | 1 | P0 | Thu | Provider, domain and region are recorded in `docs/decisions.md` with the numbers checked |
| X-03 | Give every spec §20 open question an owner and a Fri-noon deadline | §20 | none | 0.5 | P0 | Thu | Each question has an owner; answers go into `docs/decisions.md` |
| X-04 | **Access governance:** org-level MFA on Supabase, Cloudflare and GitHub; at most 3 members per org; repo **public** (decided 29 Oct: the free GitHub plan has no branch protection or environments for private repos), so secret scanning + push protection are on and no secret may ever be committed; branch protection (CI must pass, 1 review on `prod`); written rule: no prod schema edits in the dashboard | SD-6, SD-9, §15.3 | none | 1 | P0 | Thu | Screenshots of each setting are in `docs/governance.md` |
| X-05 | Triage the spec defects in §3. Agree on each fix before any spec SQL is copied | §3 | X-01 | 1 | P0 | Thu | Every SD row is marked accepted or rejected, with a reason |

---

## 3. Spec defects to fix before implementing

These were found by reading the spec's SQL and design. **None of the spec's SQL has been run.** Before fixing each item, write a test that fails (the "Proven by" column). If the test doesn't fail, close the item.

Severity: **Sec** = exploitable, **Cor** = gives a wrong result, **Gap** = a missing interface.

| ID | Sev | Defect | Fix | Task | Proven by |
|---|---|---|---|---|---|
| SD-1 | Sec | **Seat griefing.** Phone numbers aren't verified, so N throwaway emails can hold 20×N seats. `submitted` orders never expire, and a rejected order holds its seats for 24 h more. About 25 accounts are enough to make the event look sold out | `reject_order(…, p_release boolean default false)`: when true, the order goes to `expired` and its tickets to `void` straight away (for fraud and payment-not-found). Alert when pending seats exceed 15% of capacity. **Decision:** `max_tickets_per_account` stays at **20**. Admins can suspend griefing accounts (SD-5) | A-06, C-04, C-06 | A-17 |
| SD-2 | Sec | **Storage exhaustion.** Any signed-in user can upload unlimited 2 MB files to their own folder. Turnstile only guards submit, so the free storage quota can be filled | **Decision:** at most **10 uploads per user per rolling 24 h** (storage INSERT policy). **No receipt is deleted before the event**, because receipts, orphans and replaced ones are payment evidence. Orphans are deleted in the R3 purge. Backstop: `/dev/health` lists the top uploaders by bytes, and an admin suspends abusers (SD-5). *Residual risk:* one account could still upload 10 × 2 MB × 56 days ≈ 1.1 GB, which may exceed the free storage quota (check in D-16) | A-08, C-09 | A-17 |
| SD-3 | Sec | The 006 revoke only covers functions that already exist. Any function added later gets Supabase's default EXECUTE grant for `anon`/`authenticated` | `alter default privileges in schema public revoke execute on functions from public, anon, authenticated` | A-07 | A-16 |
| SD-4 | Sec | Edge Function hardening isn't specified: the path check is only `startsWith`; there's no CORS allowlist; JWT handling isn't specified; the cron secret comparison isn't constant-time; there's no body size limit; Turnstile's hostname and action aren't checked | Strict regex `^<uid>/<uuid>\.(jpg\|png\|webp\|pdf)$`; origin allowlist (prod and staging domains); `auth.getUser(jwt)`, never local decoding; `timingSafeEqual`; reject bodies over 16 KB; check Turnstile `hostname` and `action` | B-07, B-08 | B-07/B-08 Deno tests, Q-03 |
| SD-5 | Sec | There's no way to suspend an account or end the session on a stolen phone, although spec §15.1 promises "remote session revoke" | **Decision:** admins can suspend accounts. `admin_set_status(user, status, reason)` (aal2, audited): an admin can suspend or reactivate `user` accounts; only a dev can suspend an admin; nobody can suspend themselves or a dev. Suspension takes effect on the next request without a session revoke, because `is_admin()`/`is_dev()` and every write function check `status = 'active'`. So a stolen admin phone is dead as soon as its owner is suspended. A suspended user can still *read* their own orders, which is acceptable | A-06, C-05, C-07 | A-17, Q-05 |
| SD-6 | Sec | Anyone in the Supabase or Cloudflare dashboard bypasses in-app MFA, RLS and the audit trigger. The audit trigger fires on row UPDATE and DELETE but not on `TRUNCATE` | X-04 governance; add a statement-level `before truncate` trigger on `audit_log`; nightly backups serve as tamper evidence | X-04, A-04 | T12 (extended) |
| SD-7 | Sec | The receipt SHA-256 duplicate check is beaten by re-saving or re-compressing the image. The real controls are the payment reference and human review | **Decision: risk accepted.** Full-time checkers verify **every receipt against the bank statement daily** as part of review. The review screen supports them by listing other orders with the same reference, the same `paid_on` and amount, or a similar payer name. The C-11 export is a convenience (P1) | C-04, C-11, §8 Ops | Q-05 |
| SD-8 | Sec | The buyer can read `orders.review_note` through RLS | **Decision:** `review_note` is a *note to the buyer*. The admin UI labels it that way. There is no internal-notes field | C-04 | Q-03 (manual) |
| SD-9 | Sec | Retention: `notification_outbox.payload` holds QR bearer tokens and names; backup artifacts live on GitHub | The purge also clears outbox payloads and `scan_log.device_id`, and deletes **all** receipt objects, orphans included. The repo is **public**, so backup artifacts are downloadable by any GitHub user: they MUST be `age`-encrypted before upload (D-14), and CI logs must never print data | R3-02, X-04 | R3-02 check query |
| SD-10 | Cor | `admin_users_v.paid_minor` sums `total_minor` after a left join to tickets, so each order's total is multiplied by its ticket count | Aggregate orders and tickets in separate lateral subqueries | A-06 | A-12 |
| SD-11 | Cor | The language toggle (spec §13.1) calls `update_my_profile`, which sets every field. A call that only changes the language would null the name and phone | New `set_my_locale(p_locale text)`; the toggle uses it | A-05 | A-12 |
| SD-12 | Cor | `scanner_manifest()` is declared `STABLE` but writes an audit row | Mark it `VOLATILE`; check that no other STABLE function writes | A-06 | A-14 |
| SD-13 | Cor | The `check_in_ticket` regex `[0-9a-f-]{36}` lets malformed IDs (e.g. 36 dashes) reach `::uuid`, which raises an exception instead of returning `invalid` | Strict UUID regex `[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}` | A-06 | T5 |
| SD-14 | Cor | `create_order` and `resubmit_order` don't map a `check_violation` (e.g. holder name length) to `VALIDATION`. A payment ref that normalises to `''` collides on the unique index for every user | Catch `check_violation` → `VALIDATION`; reject normalised refs shorter than 4 characters | A-05 | A-12 |
| SD-15 | Cor | The 008 cron job hard-codes `<PROJECT_REF>`, which differs between staging and prod | Read the function URL from Vault (`notify_url`), the same way the secret is read | A-09 | Staging cron run in `/dev/health` |
| SD-16 | Gap | Edge Functions don't forward `x-request-id` to PostgREST, so `audit_log.request_id` is null for service-role calls | Set the supabase-js `global.headers` per request | B-07 | A-14 / Q-01 |
| SD-17 | Gap | The orders search (spec §14.1) includes holder names, but `admin_orders_v` doesn't expose them | Add a `holder_names` column (`string_agg`) to the view | A-06 | C-03 |
| SD-18 | Gap | The append-only audit trigger blocks the pseudonymisation that the purge (spec §15.4) needs | `private.purge_pii()` disables the trigger only inside its own transaction; dev only, aal2, dry-run by default | R3-01 | R3-01 |
| SD-19 | Gap | `dev_update_event_config` can't set `rejected_hold_minutes` or `max_resubmits`, and can't clear `whatsapp_group_url` | Add those fields; an explicit JSON `null` clears the URL | A-06 | A-12 |
| SD-20 | Gap | T1, T2, T3 and T7 need parallel connections, which pgTAP's single transaction can't provide | Multi-connection script in `supabase/tests/concurrency/` | A-15 | A-15 |
| SD-21 | Gap | The mail quota is shared by OTP and transactional email across 8 weeks of sales | Size it in X-02 and record it in D-16 | X-02, D-16 | D-16 |

---

## 4. R1 Sales: task tables

### 4.1 Stream A: Data & logic (Dev 1)

| ID | Task | Refs | Depends on | Est h | Pri | Day | Done when |
|---|---|---|---|---|---|---|---|
| A-01 | `supabase init`, `config.toml`, local stack, repo layout per spec §3.3 | §3.2, §3.3 | none | 1 | P0 | Thu | `supabase start` and `supabase test db` both run green on an empty test |
| A-02 | Migration 001: extensions, `private` schema, enums | §6.1 | A-01 | 1 | P0 | Thu | `supabase db reset` applies it |
| A-03 | Migration 002: tables, indexes, rejection reasons, touch triggers | §6.2, U-1 | A-02 | 2 | P0 | Thu | Reset applies; constraints spot-checked |
| A-04 | Migration 003: secrets, `is_admin`/`is_dev` (aal2), QR MAC, audit writer + **row and TRUNCATE guards**, new-user trigger, `enqueue_order_mail` | §6.3, A-1, SD-6 | A-03 | 2 | P0 | Fri | T12 covers UPDATE, DELETE **and** TRUNCATE |
| A-05 | Migration 004: user functions, plus `set_my_locale`, `check_violation` → `VALIDATION`, minimum payment-ref length | §6.4, U-2, U-5, SD-11, SD-14 | A-04, X-05 | 3 | P0 | Fri | A-12 cases for SD-11 and SD-14 pass |
| A-06 | Migration 005: admin and dev functions, plus `reject_order(…, p_release)`, `admin_set_status` (role rules per SD-5), the `admin_users_v` fix, `holder_names`, `scanner_manifest` VOLATILE, strict UUID regex, extra config fields; status checks so suspended users fail every write | §6.5, A-3, D-1, SD-1, SD-5, SD-10, SD-12, SD-13, SD-17, SD-19 | A-05 | 4.5 | P0 | Fri | T4–T10 and A-17 pass |
| A-07 | Migration 006: RLS, revokes/grants, **default privileges**, a grant block for every new function | §6.6, N-2, SD-3 | A-06 | 2 | P0 | Fri | A-16 queries return only `get_public_event` for anon |
| A-08 | Migration 007: private bucket, own-folder insert, **at most 10 inserts per user per rolling 24 h**; no update or delete policy | §6.7, SD-2 | A-07 | 1 | P0 | Fri | A-17: the 11th upload within 24 h is denied, and uploads work again after the window passes |
| A-09 | Migration 008: cron jobs; the notify URL **and** the secret come from Vault | §6.8, SD-15 | A-08 | 0.5 | P0 | Fri | On staging, `/dev/health` shows all 3 jobs succeeding |
| A-10 | `seed.sql`: event config, one test user per role (user, admin-aal1, admin-aal2, dev), local QR secret | §3.2 | A-09 | 1 | P0 | Fri | Local E2E can sign in as each role |
| A-11 | pgTAP helpers to impersonate anon, user, admin (aal1), admin (aal2) and dev through `request.jwt.claims` | §17.1 | A-04 | 2 | P0 | Fri | One sample test per role passes |
| A-12 | pgTAP: T4, T5, T6, T8, T9, T10, T12, the order rate limit, and the SD-10/11/14/19 cases | §17.1, N-3 | A-09, A-11 | 4 | P0 | Sat | All green in CI |
| A-13 | pgTAP T11: the RLS matrix (5 roles × every table, view, function **and storage path**) | §17.1, N-2 | A-12 | 3 | P0 | Sat | Matrix is green; IDOR is denied for user B reading user A's data |
| A-14 | pgTAP T13: every function writes its expected audit row(s), including `request_id` when the header is set | §17.1, A-1, D-2 | A-12 | 2 | P0 | Sat | Green |
| A-15 | Concurrency script (several `psql` connections): T1 oversell, T2 idempotency, T3 double check-in, T7 two reviewers | §17.1, §8.2, N-3, SD-20 | A-12 | 3 | P0 | Sat | 0 oversold, 1 order, 1 `ok`, 1 winner; runs in CI |
| A-16 | CI security queries: no anon/PUBLIC function grants except `get_public_event`; RLS on every `public` table; every `SECURITY DEFINER` function has `search_path=''` | §6.6, §15.3, SD-3 | A-07 | 1 | P0 | Sat | CI fails when a bad migration is added deliberately |
| A-17 | Tests for SD-1, SD-2 and SD-5: reject-and-release frees seats at once; the 11th upload in 24 h is denied; a suspended user is blocked from every write and every admin check; an admin can suspend a user but not an admin, a dev or themselves | SD-1, SD-2, SD-5 | A-08, A-11 | 2 | P0 | Sat | Green |

**Stream A total: 35 h**

### 4.2 Stream B: User flow (Dev 2)

| ID | Task | Refs | Depends on | Est h | Pri | Day | Done when |
|---|---|---|---|---|---|---|---|
| B-01 | Web scaffold: Vite, React 18, TS strict, Tailwind/shadcn, routes lazy-loaded per role, TanStack Query, Supabase client wrapper that adds `x-request-id`, App. A error mapper with `Ref:` | §12.1, §16.1, N-1, N-4 | X-01 | 3 | P0 | Thu | App deploys to the Pages preview; landing and login JS ≤ 150 KB gzip |
| B-02 | `/` landing: `get_public_event`, sold-out and paused states, language toggle slot | §12.2 | B-01, A-05 | 1.5 | P0 | Fri | Renders on staging in both languages |
| B-03 | `/login`: email → 6-digit OTP, Turnstile, `one-time-code` input | U-1, ADR-4, §5.3 | B-01, D-02 | 2 | P0 | Fri | Login works on staging; Turnstile is required |
| B-04 | Auth guard + profile step: `update_my_profile`, libphonenumber (LK region, `07x` → `+94`), handling of `PHONE_TAKEN` and `ID_NUMBER_TAKEN` | U-1, §12.3, §13.4 | B-03, D-06 | 2.5 | P0 | Fri | A Sinhala name with ZWJ saves and reloads unchanged |
| B-05 | `/buy` wizard steps 2–4: holders, payment instructions with copy buttons, review + consent; idempotency key and draft in `sessionStorage` | U-2, U-5, §12.3, §8.2 | B-04 | 5 | P0 | Sat | Refreshing mid-wizard keeps the form; a double tap creates one order |
| B-06 | Receipt: canvas re-encode (≤ 1600 px, EXIF stripped), PDF passthrough, upload to `<uid>/<uuid>.<ext>` with progress and retry; handles `UPLOAD_LIMIT` ("try again tomorrow") | §12.4, SD-2 | B-05, A-08 | 2.5 | P0 | Sat | The uploaded image has no GPS EXIF; the 11th upload in a day shows a localized error |
| B-07 | Edge `_shared`: **CORS allowlist, `auth.getUser`, Zod, 16 KB body cap, Postgres-error → App. A code map, request-id forwarding, JSON log line, `timingSafeEqual`, Sentry** | §9, §16.2, SD-4, SD-16 | X-01, D-11 | 3 | P0 | Fri | Deno tests: wrong origin → 403; forged JWT → 401; oversized body → 413 |
| B-08 | Edge `submit-order`: strict path regex, Turnstile (hostname + action), download, size + magic bytes + SHA-256, `create_order`, immediate outbox drain | §9.1, ADR-7, U-2, SD-4 | B-07, A-07, A-08 | 3 | P0 | Sat | Deno tests: `../` path, a renamed `.exe`, a 3 MB file and a bad captcha are all rejected with the right codes |
| B-09 | `/buy/done/:orderId`: "Waiting for approval", QRs, WhatsApp button, "check your email" note | U-3, §10.2 | B-08, B-10 | 1.5 | P0 | Sat | Matches the §17.2 E2E step |
| B-10 | `/orders` + `/orders/:id`: cards, timeline, display status from spec §7.3, QR at reduced opacity while pending, WhatsApp status, 10–15 s polling | U-4, U-5, §7.3, ADR-9 | B-05, A-06 | 4 | P0 | Sat | After an admin approves, the status flips to Valid within one poll |
| B-11 | `/tickets/:id`: large QR, "Save image" via canvas | U-3, §12.2 | B-10 | 1 | P0 | Sun | The saved PNG scans |
| B-12 | Edge `resubmit-order` + resubmit form + cancel button. **Keeps the old receipt** (it's evidence; this overrides spec §9.2) and records its path in the audit row |  §9.2, U-4, §7.1 | B-08, B-10 | 3 | P0/cut5 | Sun | Reject → resubmit → approve works end-to-end |

**Stream B total: 32 h**

### 4.3 Stream C: Admin & dev (Dev 3)

| ID | Task | Refs | Depends on | Est h | Pri | Day | Done when |
|---|---|---|---|---|---|---|---|
| C-01 | Admin shell: role guard, `/admin/mfa` TOTP enrolment and step-up gate for every `/admin` and `/dev` route, `staff_code` in the header, "Request admin access" button | A-1, D-1, §5.3 | B-01, A-07 | 4 | P0 | Fri | An admin at aal1 cannot reach any admin data (network tab shows 0 rows) |
| C-02 | Generic server-side table: PostgREST `range`, multi-sort (shift-click), typed filters, state in the URL, card list below 640 px with a filter bottom-sheet | A-2, §14.1, §12.7 | C-01 | 4 | P0 | Fri | Used by C-03; URLs can be bookmarked |
| C-03 | `/admin/orders`: all spec §14.1 filters, search including `holder_names`, pending badge, 10 s polling | A-2, §14.1, SD-17 | C-02, A-06 | 3 | P0 | Sat | Searching for a holder's Sinhala name finds the order |
| C-04 | `/admin` queue + `/admin/orders/:id` review: 60 s signed-URL viewer (sandboxed PDF iframe), facts panel, **neighbours panel** (same ref / same date and amount / similar payer), approve with a "note to buyer", reject sheet with **"Reject and release seats"**, race message, next in queue | A-3, §14.2, SD-1, SD-7, SD-8 | C-03 | 6 | P0 | Sat | Two-admin race shows "Already reviewed by A00x"; releasing frees seats on the landing counter |
| C-05 | `/admin/users` list (spec §14.3 columns and filters) with a **Suspend / Reactivate** row action (reason required, confirm dialog) + `/admin/users/:id` detail | A-2, §14.3, SD-5 | C-02, A-06 | 3.5 | P0 (detail: cut2) | Sun | Filters and URL state work; a suspended user's next submit returns `ACCOUNT_SUSPENDED` |
| C-06 | `/admin/analytics` basic: capacity gauge with a **pending-seat alert above 15%**, revenue, status mix, oldest pending (red when > 2 h) | A-4, §14.4, SD-1 | C-01, A-06 | 2.5 | P0 (beyond gauge: cut1) | Sun | Numbers match a hand-written SQL query on staging |
| C-07 | `/dev/admins`: pending requests, approve/revoke admin, **suspend/reactivate admins** (dev only), with confirm dialogs | D-1, SD-5 | C-01, A-06 | 3 | P0 | Sun | A suspended admin's phone gets 0 rows and `FORBIDDEN` on its next request |
| C-08 | `/dev/audit`: filter by actor, action, entity and time; diff view of before/after data | D-2, §16 | C-02 | 2 | P0 | Sun | Approve, reject and config changes are all visible with `staff_code` |
| C-09 | `/dev/health`: `dev_health()` (outbox, dead letters, cron, DB size, receipts) plus **storage used vs quota and the top 10 uploaders by bytes** | D-2, §16, SD-2 | C-01, A-06 | 2 | P0 | Sun | A dead notification shows a red badge; a seeded heavy uploader appears first |
| C-10 | `/dev/config`: price, sales window, capacity, limits, hold time, resubmit limit, bank details, WhatsApp link (clearable), pause sales | §12.2, SD-19 | C-01, A-06 | 2.5 | P0 | Sun | Pausing sales makes the landing page show "paused" within one poll |
| C-11 | Reconciliation export: approved orders as CSV with BOM (order no, payer, bank, ref, paid_on, amount, reviewer). A convenience for the daily checkers | SD-7, §13.8 | C-03 | 1.5 | P1 (cut6) | Sun | Opens correctly in Excel with Sinhala names |

**Stream C total: 34 h**

### 4.4 Stream D: Platform, i18n & notifications (Dev 4)

| ID | Task | Refs | Depends on | Est h | Pri | Day | Done when |
|---|---|---|---|---|---|---|---|
| D-01 | Supabase staging and prod projects in the chosen region; Cloudflare Pages project; App. B env vars; secrets in Vault and Edge env; QR secret inserted in each environment | §3.2, §4, App. B | X-02, X-04 | 2 | P0 | Thu | Both environments are reachable; no secret is in git |
| D-02 | Domain DNS, SPF/DKIM/DMARC, Supabase custom SMTP; Auth hardening: short OTP expiry, rate limits at default or stricter, redirect URLs limited to app domains, Turnstile enabled in Auth | R-1, §15.3 | X-02, D-01 | 2 | P0 | Fri | Mail-tester score ≥ 9/10; DMARC passes in Gmail headers |
| D-03 | CI: lint, typecheck, `pnpm i18n:check`, gitleaks, `pnpm audit` (fails on high), `supabase test db` + A-15 + A-16; migrations deploy to staging on `main` and to prod on tag **with manual approval** | §3.2, §15.3 | A-01, B-01 | 4 | P0 | Fri | A planted test secret fails the build |
| D-04 | i18n framework: i18next, detection order (profile → localStorage → navigator → en), header toggle on every screen calling `set_my_locale`, `<html lang>`, `no-literal-string` lint, `i18n:check` script | L-1, §13.1, §13.2, SD-11 | B-01 | 3 | P0 | Fri | Toggling on `/buy` keeps the form state |
| D-05 | Noto Sans Sinhala subset (U+0D80–0DFF + ZWJ/ZWNJ, `--layout-features='*'`), preload, CSS from spec §13.3 | §13.3 | B-01 | 1.5 | P0 | Fri | Conjuncts render correctly on an old Android phone |
| D-06 | Shared formatters (money, Colombo time, Latin digits), grapheme utilities (`Intl.Segmenter`), Zod name and phone schemas used by both web and Edge | §13.4, §13.5 | B-01 | 2 | P0 | Fri | Unit tests cover Sinhala names with ZWJ |
| D-07 | Bilingual OTP email template (Sinhala first, large monospace code) | §13.7 | D-02 | 1 | P0 | Fri | Renders in Gmail web and Gmail on Android |
| D-08 | Mail templates for 5 kinds × 2 locales: **every interpolated value HTML-escaped**, inline QR PNGs with `Content-ID`, plain-text part, no receipts | §10.1, §13.7, §15.1 | D-06, X-01 | 4 | P0 | Sat | Unit test: a holder name `<img onerror>` is escaped |
| D-09 | Edge `send-notifications`: cron secret (constant-time), claim → render → send → mark | §9.3, ADR-8 | D-08, A-09, B-07 | 2.5 | P0 | Sat | The outbox drains in under 2 min; failures back off; 6 failures → `dead` |
| D-10 | Edge `health` (public `select 1`; token-protected detail mode) + UptimeRobot on the app and `/health` | §9.4, R-2, N-5 | B-07 | 1 | P0 | Sat | The monitor alerts when the function is disabled |
| D-11 | Sentry for web and Edge: `sendDefaultPii: false`, `beforeSend` strips emails, phones and bodies; release = git SHA | §15.4, §16 | B-01 | 1.5 | P0 | Fri | A test error arrives with no PII |
| D-12 | `_headers`: CSP from spec §15.2 in report-only mode on staging, then enforced; `frame-src` and `img-src` adjusted for the receipt viewer | §15.2 | B-01, C-04 | 1.5 | P0 | Sun | No CSP violations on any screen while enforced |
| D-13 | PWA: manifest, precache of the app shell only, **no API caching**, bilingual offline page, update toast | §12.5, N-1 | B-01 | 1.5 | P0/cut3 | Sun | The service worker cache contains no `supabase.co` responses |
| D-14 | `backup.yml`: nightly `pg_dump` → `age` encryption → artifact (7 days); **restore tested on staging** | §16.4, R-2 | D-01, D-03 | 2.5 | P0 | Sat | The restored staging DB passes A-12 |
| D-15 | Native Sinhala review of `si.json`, emails and the privacy notice; event owner signs off the privacy notice | §13.2, §15.4, §20 Q9/Q12 | D-04, D-08 | 1 | P0 | Sat–Sun | Sign-off is recorded in `docs/decisions.md` |
| D-16 | `docs/quotas.md`: every provider's current free limits vs our footprint across 8 weeks (DB, storage, egress, invocations, auth mail, transactional mail per day and per month). **Storage must account for receipts being kept until the event** (no deletion) and for the SD-2 worst case | R-3, N-6, SD-2, SD-21 | X-02 | 1 | P0 | Fri | Every row has headroom ≥ 2×, or the shortfall is escalated with a mitigation |

**Stream D total: 32 h**

### 4.5 QA & release

| ID | Task | Refs | Depends on | Est h | Pri | Day | Done when |
|---|---|---|---|---|---|---|---|
| Q-01 | Playwright E2E against the **local stack with the Mailpit OTP inbox**: buy 3 tickets → confirmation; admin MFA → approve → user sees Valid; reject → resubmit; reject-and-release; all in `en` and `si`; Sinhala snapshot at 360 px. One smoke run on staging | §17.2 | B-12, C-04, D-04 | 5 | P0 | Sun | Green in CI |
| Q-02 | k6: 50 virtual users for 5 min (browse → login → submit → poll) on staging | §17.3 | B-08 | 1.5 | P0/cut4 | Sun | Error rate < 1 %, p95 within spec §17.3, nothing oversold |
| Q-03 | Security release gate: spec §15.3 checklist, plus manual IDOR probing with two accounts, anon-key probing of every table and RPC, CSP check, Edge hardening checks (SD-4), `review_note` exposure check (SD-8) | §15.3, N-2 | A-16, B-08, D-12 | 3 | P0 | Sun | Every box ticked and initialled in `docs/release-r1.md` |
| Q-04 | Localisation checklist (spec §13.9) on an old Android phone, an iPhone and Excel | §13.9, L-1 | D-04, D-05, D-15 | 2 | P0 | Sun | Every box ticked |
| Q-05 | **Dry run Sun 1 Nov:** two real phones, one real bank transfer, two admins; reject → resubmit → approve; reject-and-release; a checker matches receipts against the bank statement; an admin suspends a user, and a dev suspends an admin | §17.4 | Q-01, Q-03 | 3 (each) | P0 | Sun | A written go/no-go note |
| Q-06 | **Prod release Mon 2 Nov:** fresh `pg_dump` before migrating (policy: fix forward only); apply migrations through CI; insert secrets; seed config, bank details and WhatsApp link; create the first dev; promote admins and confirm their MFA; smoke test; unpause sales. Document `sales_paused` as the kill switch | §18, §19 | Q-05 | 2.5 | P0 | Mon | The smoke order is approved in prod, then cancelled |

**QA total: 17 h** (Q-05 counted once)

### 4.6 Critical path

```
X-01 → A-02..A-07 → B-08 → B-09/B-10 → Q-01 → Q-05 → Q-06
             └──────→ C-01 → C-02 → C-03 → C-04 ┘
D-01 → D-02 (SMTP) ──→ B-03 (OTP login)
```

**D-02 is the biggest outside risk** because DNS propagation and DKIM verification can take hours. Start it Thu evening.

---

## 5. R1.1, R2 Gate, R3 Close-out

### 5.1 R1.1 Steady state (3–15 Nov)

| ID | Task | Refs | Depends on | Est h | Pri | Done when |
|---|---|---|---|---|---|---|
| R11-01 | WhatsApp "Mark added" flow: column with copy button, "unmatched" filter, user-facing badge | A-6, §10.2 | C-05 | 3 | P1 | An admin can match a join request in under 30 s |
| R11-02 | Full analytics panels: turnaround, sales by day, rejection reasons, reviewer throughput | A-4, §14.4 | C-06 | 3 | P1 | Matches SQL |
| R11-03 | Anything cut from R1 (§1.2) | | | n/a | P0 | Shipped |
| R11-04 | ICU collation check (`si-LK-x-icu`) and Sinhala sort | §13.8 | C-03 | 1 | P1 | Decision recorded |
| R11-05 | Edge `purge-event-data` + `private.purge_pii()` built and tested on staging (dry run by default) | §9.5, §15.4, SD-9, SD-18 | A-06 | 4 | P0 | A staging dry run lists the expected counts; an execute run on a staging copy leaves no PII |
| R11-06 | Saved filter views, wa.me contact button | §18.1 | C-03 | 2 | P2 | n/a |

### 5.2 R2 Gate (code complete 5 Dec · drill 12 Dec · freeze 19 Dec · event 26 Dec)

| ID | Task | Refs | Depends on | Est h | Pri | Done when |
|---|---|---|---|---|---|---|
| G-01 | `/admin/scan` online: `qr-scanner` with `html5-qrcode` fallback, camera start on user gesture, 2 s debounce, gate label, full-screen result with sound and vibration, wake lock | A-5, §11.2 | C-01 | 5 | P0 | Every one of the 5 results displays correctly on two phones |
| G-02 | Manual lookup (short code or name) + undo check-in (reason required) | A-5, §11.2 | G-01 | 3 | P0 | A damaged-QR case is handled |
| G-03 | `/admin/door-list`: search, filter, CSV with BOM, A4 print stylesheet using the Sinhala font | §14.5, N-5 | C-02 | 2 | P0 | The printed list is readable at the gate |
| G-04 | Check-in analytics: total, per gate, per 10 min | A-4, §14.4 | C-06 | 1.5 | P1 | Matches `scan_log` |
| G-05 | Offline scanner: manifest into IndexedDB, local SHA-256 lookup, queued sync, conflicts view, cache cleared on sign-out | §11.4, ADR-11 | G-01 | 8 | **P0** | The drill with flight mode on shows a correct conflict after sync |
| G-06 | Enrol scanner devices: each admin's own phone, MFA, screen lock, gate name; one spare | §15.1, §19 | G-01 | 1 | P0 | Every device has been tested |
| G-07 | **Gate drill on staging (12 Dec):** 50 test tickets, 2 gates, connection loss, double scan, undo, revoke a stolen device | §17.4, §19 | G-01…G-06 | 3 | P0 | Go/no-go note |
| G-08 | Close sales; final bank reconciliation; door list printed (sorted by holder name); final backup | §19, SD-7 | G-03, C-11 | 2 | P0 | Every approved order matches a bank line |
| G-09 | `qr_version` reissue procedure (dev SQL, audited) written and rehearsed | §11.1 | A-06 | 1 | P1 | Done once on staging |
| G-10 | Print the runbook (spec §19) and brief gate and desk staff | §19 | G-07 | 1 | P0 | Staff have signed the briefing sheet |

### 5.3 R3 Close-out (event + 7 days = Sat 2 Jan 2027)

| ID | Task | Refs | Depends on | Est h | Pri | Done when |
|---|---|---|---|---|---|---|
| R3-01 | Review `private.purge_pii()` (built in R11-05) and get event-owner sign-off | SD-18, §15.4 | R11-05 | 1 | P0 | Signed off |
| R3-02 | Run the purge in prod: **all** receipts via the Storage API (orphaned and replaced ones included); null the PII columns; clear outbox payloads and `scan_log.device_id`; pseudonymise the audit log | §15.4, SD-9 | R3-01 | 2 | P0 | Check queries return 0 PII rows; the bucket is empty |
| R3-03 | Decommission staging, rotate or revoke all secrets and keys, delete backup artifacts once they're no longer needed | §15.4 | R3-02 | 1 | P0 | Checklist complete |

---

## 6. Security traceability

Every threat in spec §15.1 and every `Sec` defect maps to a control, the task that implements it, and the test that proves it. A row without a test is a release blocker.

| Threat / defect | Control | Implemented in | Proven by |
|---|---|---|---|
| Forged or edited QR | HMAC-SHA256 payload, verified in SQL; secret only in `private.secrets` | A-04, A-06 | T5 |
| Screenshot shared with a non-buyer | Single-use atomic check-in; holder name shown on the result | A-06, G-01 | T3, G-07 |
| Receipt reused across orders | SHA-256 and payment-ref unique indexes on live orders; neighbours panel; daily bank check | A-03, C-04, §8 | T8, Q-05 |
| Fake or edited receipt | Full-time checkers verify every receipt against the bank statement daily | C-04, §8 | Q-05, G-08 |
| Overselling | `event_config` row lock + capacity check in one transaction | A-05 | T1 (A-15) |
| Double submit or retries | Idempotency key + unique index + replay check after the lock | A-05, B-05 | T2 (A-15) |
| User → admin escalation | No direct writes; role only changes in `dev_set_admin` (dev + aal2) | A-06, A-07 | T11, A-16 |
| Admin account takeover | aal2 required inside RLS; per-person accounts; dev suspends the admin (takes effect on the next request) | A-04, A-06, C-07 | T11, A-17, Q-05 |
| Insider approval fraud | Four-eyes rule; `staff_code` on every action; per-reviewer analytics | A-06, C-06, R11-02 | T10, T13 |
| IDOR (orders, tickets, receipts) | RLS on every table; storage policies by folder; 60 s signed URLs | A-07, A-08 | T11, Q-03 |
| XSS (names, notes, reasons) | React escaping, no `dangerouslySetInnerHTML`, strict CSP, escaped email templates | D-08, D-12 | D-08 unit test, Q-03 |
| Session token theft | CSP with no third-party scripts beyond Turnstile and Sentry; lockfile; `pnpm audit`; gitleaks | D-03, D-12 | Q-03 |
| Bots, signup spam, OTP flooding | Turnstile in Auth and submit (hostname + action); Auth rate limits; per-buyer order rate limit | B-03, B-08, D-02, A-05 | A-12, Q-03 |
| Malicious upload | Size + magic bytes on the server; bucket MIME list; private objects; sandboxed PDF iframe | B-08, A-08, C-04 | B-08 Deno tests, Q-03 |
| DB leak | Secrets only in `private.*` and Edge env; minimal PII; purge | A-04, R3-02 | A-16, R3-02 |
| Stolen scanner device | MFA; suspend the device owner's account; offline cache cleared on sign-out; screen lock | A-06, C-07, G-05, G-06 | A-17, G-07 |
| Account enumeration (phone/ID) | **Accepted risk** (spec §5.2); OTP flow answers the same for known and unknown emails | D-02 | Q-03 (OTP response check) |
| **SD-1** Seat griefing | Reject-and-release; pending-seat alert; suspend accounts (per-account limit stays 20) | A-06, C-04, C-05, C-06 | A-17 |
| **SD-2** Storage exhaustion | 10 uploads per user per day; top-uploader monitor; suspend accounts; deletion only in the R3 purge | A-08, C-09, C-05 | A-17, C-09 |
| **SD-3** Default function grants | `alter default privileges` revoke; CI query | A-07, A-16 | A-16 |
| **SD-4** Edge hardening | CORS allowlist, `getUser`, strict path, body cap, constant-time secret, Turnstile hostname + action | B-07, B-08, D-09 | B-07/B-08 Deno tests, Q-03 |
| **SD-5** No suspend or revoke | `admin_set_status` (admins suspend users; devs suspend admins); status checked on every request | A-06, C-05, C-07 | A-17, Q-05 |
| **SD-6** Dashboard superuser, TRUNCATE | Org MFA, minimal members; TRUNCATE guard; backups | X-04, A-04, D-14 | T12, X-04 screenshots |
| **SD-7** Weak receipt dedupe | **Accepted risk.** Daily manual check of every receipt against the bank statement; neighbours panel | C-04, §8 | Q-05, G-08 |
| **SD-8** `review_note` visible to buyer | Defined as a note to the buyer; labelled in the UI | C-04 | Q-03 |
| **SD-9** Retention of tokens and PII | Purge covers the outbox and scan log; private repo | R3-02, X-04 | R3-02 |

---

## 7. Requirement coverage

| Req | Delivered by | Release |
|---|---|---|
| D-1 Approve/revoke admins, MFA | A-06, C-01, C-07, X-04 | R1 |
| D-2 Full observability | A-04, C-08, C-09, D-10, D-11, D-14 | R1 |
| A-1 Uniquely identifiable admins | A-04, A-06, C-01, A-14 | R1 |
| A-2 User/order lists with filter, sort, search, pagination | A-06, C-02, C-03, C-05 | R1 |
| A-3 Approve/reject with reason | A-06, C-04, D-08, D-09 | R1 |
| A-4 Payment analytics | C-06 (basic), R11-02 (full), G-04 (check-ins) | R1 / R1.1 / R2 |
| A-5 Gate scanning + manual lookup | A-06 (SQL), A-15 (T3), G-01, G-02, G-03, G-05 | R1 (SQL) / R2 (UI) |
| A-6 WhatsApp match + mark added | A-06 (SQL), R11-01 | R1.1 |
| U-1 Unique users | A-03, B-03, B-04 | R1 |
| U-2 Purchase form + receipt | B-05, B-06, B-08 | R1 |
| U-3 Confirmation email with QR + WhatsApp link | B-09, B-11, D-08, D-09 | R1 |
| U-4 Track progress per order and ticket | B-10, B-12 | R1 |
| U-5 Multiple orders, many holders | B-05, B-10 | R1 |
| L-1 Sinhala + English everywhere | D-04, D-05, D-06, D-07, D-08, D-15, Q-04 | R1 |
| N-1 Mobile-first | B-01, C-02, D-13, Q-04 | R1 |
| N-2 Safety | All of §6; A-07, A-13, A-16, D-12, Q-03 | R1 |
| N-3 Deterministic and atomic | A-05, A-06, A-15 | R1 |
| N-4 Fast | B-01 (bundle budget), Q-02 | R1 |
| N-5 Uptime | D-10, D-14, G-03, G-05 | R1 / R2 |
| N-6 Free hosting | X-02, D-01, D-16 | R1 |

---

## 8. Operations during the sales period (2 Nov → 26 Dec)

The system runs live for 8 weeks, so these jobs need a named owner on a rota.

| Cadence | Check | Owner |
|---|---|---|
| Daily | `/dev/health`: no `dead` notifications, outbox oldest < 10 min, all cron jobs succeeded | rota |
| Daily (9:00–21:00 Colombo) | Oldest `submitted` order < 2 h; pending seats < 15% of capacity | admins |
| Daily (full-time) | **Receipt check:** every submitted receipt is verified against the bank statement before approval | checkers (admins) |
| Daily | Storage used vs quota and top uploaders on `/dev/health`; suspend abusers | rota |
| Weekly | Backup restore test on staging | Dev 4 |
| Weekly | `pnpm audit`, Supabase/Sentry/mail quota review against `docs/quotas.md` | Dev 4 |
| Weekly | Review the admin list; revoke anyone who no longer needs access | Dev 1 |
| On incident | `sales_paused = true` via `/dev/config` (kill switch), then follow spec §19 | any dev |
