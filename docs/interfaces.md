# Interfaces (X-01): frozen contract for streams B, C and D

**Version 1, frozen 29 Oct 2026.** This is what the web app, the Edge Functions and the emails are built against.
The database side is implemented and tested (`supabase/tests/`); the Edge Function side is the contract they must implement.

**Changing anything here** needs a PR that edits this file, plus the release lead's approval. Additive changes
(a new optional field, a new error code) are fine; renames and removals are not, after Fri 30 Oct.

Where this file and the spec (`ticketing-architecture.md`) disagree, **this file wins**: it includes the spec-defect
fixes (work plan §3) and later decisions. The overrides are listed in §9.

---

## 1. Conventions

| Topic | Rule |
|---|---|
| Calling the DB | supabase-js: `supabase.rpc('<name>', { p_…: … })` for functions; `supabase.from('<table or view>').select(…)` for reads. **No direct writes**: every write is a function |
| Errors from functions | Business errors are raised as Postgres exceptions whose **message is the code**: PostgREST returns `{ "code": "P0001", "message": "CAPACITY_EXCEEDED" }`. The client maps `message` → `errors.<CODE>` (§7). Anything else (e.g. `42501` permission denied) → `errors.INTERNAL`, or `UNAUTHENTICATED` if there is no session |
| Errors from Edge Functions | `{ "error": { "code": "<CODE>", "request_id": "<uuid>" } }` with the HTTP status in §7 |
| Money | Integer **minor units** (LKR cents): `unit_price_minor`, `total_minor`. Format on the client (§13.5) |
| Time | `timestamptz`, ISO 8601 UTC on the wire. Display in `Asia/Colombo` |
| Locale | `'si'` or `'en'` only |
| Phone | E.164 (`+94771234567`). The client converts `07x…` before sending |
| IDs shown to people | `public_code` (`U-7K3Q9X`), `order_no` (`ORD-…`), ticket `short_code` (`T-…`), `staff_code` (`A001`, `D001`). Never show UUIDs |
| Request id | The web app sends `x-request-id: <uuid>` on every call; Edge Functions forward it to PostgREST (SD-16), so it lands in `audit_log.request_id` |

**Roles.** `anon` (no session) · `user` (signed in, any role, aal1 is enough) · `admin` (role admin **or** dev, **aal2 required**) · `dev` (role dev, **aal2 required**) · `service` (Edge Functions / cron with the service-role key).
A **suspended** account keeps read access to its own data but fails every write with `ACCOUNT_SUSPENDED`, and fails every admin/dev check with `FORBIDDEN` (SD-5).

---

## 2. Database functions (RPC)

Access is enforced twice: an EXECUTE grant per role, and a check inside the function. The full matrix is tested in
`supabase/tests/013_function_matrix.test.sql`, which **fails if a function is added without being listed there**.

### 2.1 Public and user

| Function | Caller | Returns | Errors |
|---|---|---|---|
| `get_public_event()` | anon, user | `{ name, venue, starts_at, unit_price_minor, currency, sales_open_at, sales_close_at, sales_paused, max_tickets_per_order, sold_out }`, or `null` before the event is configured | |
| `get_payment_instructions()` | user | `{ bank, account_name, account_no, branch, note_en, note_si }` | |
| `get_whatsapp_group()` | user | the group URL, or `null` unless the user has a submitted/approved/rejected order | |
| `update_my_profile(p_full_name, p_phone_e164, p_whatsapp_e164, p_id_number, p_locale)` | user | the `profiles` row | `UNAUTHENTICATED`, `ACCOUNT_SUSPENDED`, `PHONE_TAKEN`, `ID_NUMBER_TAKEN`, `VALIDATION` |
| `set_my_locale(p_locale)` | user | — | `UNAUTHENTICATED`, `VALIDATION`. **The language toggle uses this**, never `update_my_profile` (SD-11). Works for suspended users |
| `request_admin_access()` | user | — | `UNAUTHENTICATED` |
| `cancel_my_order(p_order_id)` | user | — | `UNAUTHENTICATED`, `ACCOUNT_SUSPENDED`, `NOT_FOUND`, `INVALID_TRANSITION` (only `submitted` / `rejected`) |
| `my_order_tickets(p_order_id)` | user (own), admin | rows `{ ticket_id, seq, holder_name, short_code, status, qr }`; `qr` is the payload to render. Void tickets omitted | (another user's order → 0 rows) |
| `my_upload_quota()` | user | `{ limit: 10, used, remaining }` (rolling 24 h). Check before uploading; `remaining = 0` → show `errors.UPLOAD_LIMIT` | |

### 2.2 Admin (aal2)

| Function | Returns | Errors / notes |
|---|---|---|
| `approve_order(p_order_id, p_note default null)` | the `orders` row | `FORBIDDEN`, `NOT_FOUND`, `SELF_REVIEW_FORBIDDEN`, `INVALID_TRANSITION` (someone else reviewed it: reload and show `reviewer_code`). `p_note` is a **note to the buyer** (SD-8) |
| `reject_order(p_order_id, p_reason_code, p_reason_text default null, p_release default false)` | the `orders` row | as above + `VALIDATION` (unknown/inactive reason), `REASON_TEXT_REQUIRED` (`other` needs ≥ 3 chars). `p_release = true` = **"Reject and release seats"**: status becomes `expired`, tickets `void` at once (SD-1); otherwise `rejected` with seats held until `hold_expires_at` |
| `check_in_ticket(p_payload, p_gate, p_device default null, p_scanned_at default null, p_offline default false)` | `{ result, ticket_id, short_code, holder_name, seq, order_no, checked_in_at, checked_in_gate }`; `result` ∈ `ok`, `waiting_approval`, `already_used`, `void`, `invalid` (then only `{ result }`) | `FORBIDDEN`. Never throws for a bad payload |
| `admin_undo_check_in(p_ticket_id, p_reason)` | — | `FORBIDDEN`, `REASON_TEXT_REQUIRED`, `INVALID_TRANSITION` |
| `scanner_manifest()` (P1) | rows `{ ticket_id, payload_sha256, short_code, holder_name, status, order_no }` | `FORBIDDEN`. Audited. No secret leaves the server |
| `sync_offline_scans(p_scans)` (P1) | array of `check_in_ticket` results, in input order. Input `[{ payload, gate, device, scanned_at }]`, max 1000 | `FORBIDDEN`, `VALIDATION` |
| `mark_whatsapp_added(p_user_id, p_added)` | — | `FORBIDDEN`, `NOT_FOUND` |
| `admin_set_status(p_user_id, p_status, p_reason)` | — | `FORBIDDEN` (self, a dev, or an admin unless you're a dev), `NOT_FOUND`, `REASON_TEXT_REQUIRED`, `VALIDATION`. `p_status` ∈ `active`, `suspended` |
| `admin_analytics()` | `{ capacity, tickets_by_status, orders_by_status{status:{orders,amount_minor}}, turnaround_sec{p50,p90}, pending_oldest_sec, rejections_by_reason, sales_by_day[{day,tickets,amount_minor}], reviews_by_admin[{staff_code,approved,rejected}], checkins_by_gate, checkins_per_10min[{t,n}] }`. Pending-seat alert (SD-1) = `tickets_by_status.pending / capacity > 0.15` | `FORBIDDEN` |

### 2.3 Dev (aal2)

| Function | Returns | Errors / notes |
|---|---|---|
| `dev_set_admin(p_user_id, p_make_admin)` | — | `FORBIDDEN` (self, or target is a dev), `NOT_FOUND`. Granting assigns the next `A0nn` staff code |
| `dev_update_event_config(p)` | — | `FORBIDDEN`, `VALIDATION`. **Partial update**: absent keys are kept; `"whatsapp_group_url": null` clears it. Keys: `name, venue, starts_at, capacity, unit_price_minor, sales_open_at, sales_close_at, sales_paused, max_tickets_per_order, max_tickets_per_account, rejected_hold_minutes, max_resubmits, whatsapp_group_url, bank_details`. **Creates the row on first use** (then `name, starts_at, capacity, unit_price_minor, sales_open_at, sales_close_at` are required) |
| `dev_health()` | `{ outbox{status:n}, outbox_oldest_queued_sec, orders{status:n}, db_bytes, receipt_objects{count,bytes}, top_uploaders[{user_code,email,objects,bytes}], cron_last_runs[{jobname,status,start_time}] }` | `FORBIDDEN` |

### 2.4 Service role only (Edge Functions, cron)

| Function | Used by | Returns | Errors |
|---|---|---|---|
| `create_order(p_buyer_id, p_idempotency_key, p_holders, p_payer_name, p_bank_name, p_payment_ref, p_paid_on, p_receipt_path, p_receipt_sha256, p_receipt_mime, p_receipt_bytes)` | `submit-order` | `{ order_id, order_no, status, replayed }` | `SALES_CLOSED`, `NOT_FOUND`, `ACCOUNT_SUSPENDED`, `PROFILE_INCOMPLETE`, `TOO_MANY_TICKETS_IN_ORDER`, `RATE_LIMITED` (5 orders/h), `ACCOUNT_LIMIT`, `CAPACITY_EXCEEDED`, `DUPLICATE_RECEIPT`, `DUPLICATE_PAYMENT_REF`, `VALIDATION` (ref < 4 chars after normalising, bad holder names, …) |
| `resubmit_order(p_buyer_id, p_order_id, p_payer_name, p_bank_name, p_payment_ref, p_paid_on, p_receipt_path, p_receipt_sha256, p_receipt_mime, p_receipt_bytes)` | `resubmit-order` | `{ order_id, status, old_receipt_path }` | `ACCOUNT_SUSPENDED`, `NOT_FOUND`, `INVALID_TRANSITION`, `HOLD_EXPIRED`, `RESUBMIT_LIMIT`, `DUPLICATE_*`, `VALIDATION` |
| `claim_notifications(p_limit default 20)` | `send-notifications` | `notification_outbox` rows, now `sending` | |
| `mark_notification(p_id, p_ok, p_error default null)` | `send-notifications` | — | Retries with back-off; `dead` after 6 attempts |
| `expire_stale_orders()` | cron (every 5 min) | number expired | |

`p_holders` = `[{ "name": "…", "phone": "+94…" | omitted }, …]`, first entry is the buyer by convention, 1..`max_tickets_per_order`.
Payment refs are normalised to `A-Z0-9` upper-case before storing and comparing.

---

## 3. Reads (tables and views, through RLS)

| Relation | user | admin (aal2) | dev |
|---|---|---|---|
| `profiles` | own row | all | all |
| `orders`, `tickets` | own | all | all |
| `rejection_reasons` | all (`code, label_en, label_si, sort, active`) | all | all |
| `event_config` | — (use `get_public_event`) | read | read (write via `dev_update_event_config`) |
| `scan_log` | — | all | all |
| `audit_log`, `notification_outbox` | — | — | all |
| `admin_orders_v` | own orders only | all | all |
| `admin_users_v` (plain users only) | own row | all | all |
| `admin_door_list_v` | own valid/used tickets | all | all |

`anon` can read nothing directly. Admin and dev without aal2 see only their own rows.

**`admin_orders_v`**: `id, order_no, status, ticket_count, total_minor, currency, payer_name, bank_name, payment_ref, paid_on, submitted_at, last_submitted_at, reviewed_at, resubmit_count, reject_reason_code, reject_reason_text, review_note, receipt_path, receipt_mime, reviewer_code, buyer_id, buyer_code, buyer_name, buyer_email, buyer_phone, buyer_whatsapp, whatsapp_added_at, buyer_locale, checked_in_count, holder_names` (comma-joined, for search, SD-17).
**`admin_users_v`**: `id, public_code, full_name, email, phone_e164, whatsapp_e164, id_number, locale, status, whatsapp_added_at, created_at, orders, tickets, approved_tickets, checked_in, paid_minor, last_order_at`.
**`admin_door_list_v`**: `short_code, holder_name, status, order_no, buyer_name, buyer_phone`.
Filter, sort and paginate with PostgREST (`.ilike`, `.order`, `.range`) and `count: 'exact'`.

---

## 4. Storage (receipts)

| Rule | Value |
|---|---|
| Bucket | `receipts`, private, **5 MB per file**, JPEG, PNG, WebP or PDF (most buyers upload bank PDFs) |
| Path | `{uid}/{uuid}.{ext}`: the user's own id, a fresh random UUID, and `ext` one of `jpg`, `png`, `webp`, `pdf`. Anything else is refused |
| Upload | user, into their own folder only; **10 per rolling 24 h** (`my_upload_quota()`); suspended users can't upload |
| Read | owner, or admin (aal2) via `createSignedUrl(path, 60)` |
| Update / delete | nobody through the API. **No receipt is deleted before the event**, not even replaced or orphaned ones (SD-2) |

A refused upload comes back from Storage as HTTP 400 with an RLS message; the client can't tell "quota" from "bad path",
so check `my_upload_quota()` first and always generate the path itself.

---

## 5. Edge Functions

Base URL: `https://<project-ref>.supabase.co/functions/v1/<name>`.

### 5.0 Rules for every function (B-07 `_shared`, SD-4, SD-16)

- **CORS allowlist:** `https://mystique-26.pages.dev`, `https://mystique-staging.pages.dev`, and `http://localhost:5173` on staging only. Other origins → `403 FORBIDDEN`.
- **Auth:** `Authorization: Bearer <user JWT>` verified with `auth.getUser(jwt)` (never decoded locally) → `401 UNAUTHENTICATED`.
- **Body:** JSON, max **16 KB** → `413 PAYLOAD_TOO_LARGE`; validated with Zod → `400 VALIDATION`.
- **Request id:** read `x-request-id` (or generate one), forward it to PostgREST via `global.headers`, return it in every error body, log it.
- **Errors:** map the Postgres message to the codes in §7; anything unmapped → `500 INTERNAL` (logged with the request id, details never returned).
- **Logs:** one JSON line per request: `{ fn, request_id, user_id, status, ms, code }`. Never log receipts, tokens, or personal data.

### 5.1 `submit-order` (POST, user JWT)

```jsonc
// request (≤ 16 KB)
{
  "idempotency_key": "uuid",              // generated when the form opens, reused on every retry
  "turnstile_token": "…",                 // action "submit-order"
  "holders": [ { "name": "Nimal Perera", "phone": "+94771234567" }, { "name": "…" } ],
  "payment": { "payer_name": "…", "bank_name": "…", "reference": "…", "paid_on": "2026-11-01" },
  "receipt_path": "<uid>/<uuid>.jpg"
}
// 201 (or 200 when "replayed": true)
{ "order_id": "uuid", "order_no": "ORD-7K3Q9X", "status": "submitted", "replayed": false,
  "whatsapp_group_url": "https://chat.whatsapp.com/…" }
```

Steps: auth → Zod → Turnstile (check `success`, `hostname` and `action`; skip if the key replays an existing order)
→ `receipt_path` must match `^<uid>/[0-9a-f-]{36}\.(jpg|png|webp|pdf)$` → download with the service role, check size ≤ 5 MB,
magic bytes match the extension (`FFD8FF`, `89504E47`, `RIFF…WEBP`, `%PDF`), compute SHA-256 → `RECEIPT_INVALID` (422) on
any mismatch → `create_order` → best-effort immediate outbox drain → return.

### 5.2 `resubmit-order` (POST, user JWT)

```jsonc
// request
{ "order_id": "uuid", "turnstile_token": "…",                 // action "resubmit-order"
  "payment": { "payer_name": "…", "bank_name": "…", "reference": "…", "paid_on": "2026-11-02" },
  "receipt_path": "<uid>/<uuid>.png" }
// 200
{ "order_id": "uuid", "status": "submitted" }
```

Same checks as `submit-order`, then `resubmit_order`. **The old receipt is kept** (SD-2): the spec's "delete
`old_receipt_path`" step is dropped.

### 5.3 `send-notifications` (POST, cron)

Header `x-cron-secret: <CRON_SECRET>`, compared in constant time → `401` otherwise. Body `{}`.
Loop `claim_notifications(20)` → render the template for `kind` × `locale` (§8) → send → `mark_notification(id, ok, error)`;
stop after ~50 s. Returns `{ "sent": n, "failed": n }`. Mail transport: **Gmail SMTP over TLS on port 465**, using the
`SMTP_USER` / `SMTP_PASS` secrets (X-02: tested from a staging Edge Function on 29 Oct, login OK in ~2 s).

### 5.4 `health` (GET, public)

`200 { "ok": true, "t": <epoch> }` or `503`. With `x-health-token: <HEALTH_TOKEN>`: adds `{ outbox_due, outbox_dead, cron_last_runs }`.

### 5.5 `purge-event-data` (POST, dev JWT + aal2) — R3, after the event

Dry run by default; `?execute=true` to act. Deletes **all** receipt objects through the Storage API, nulls PII, clears
outbox payloads and `scan_log.device_id`, pseudonymises the audit log (SD-9, SD-18).

---

## 6. Routes (web)

| Route | Access | Guard |
|---|---|---|
| `/` | public | |
| `/login` | public | Signed in → redirect to `?next` or `/orders` |
| `/buy`, `/buy/done/:orderId`, `/orders`, `/orders/:id`, `/tickets/:id` | user | No session → `/login?next=…`. `/buy` sends incomplete profiles to step 1 |
| `/admin`, `/admin/orders`, `/admin/orders/:id`, `/admin/users`, `/admin/users/:id`, `/admin/analytics`, `/admin/scan`, `/admin/door-list` | admin | Role admin/dev **and** aal2, else → `/admin/mfa` (enrol or step up). Role user → `/` |
| `/admin/mfa` | admin, dev | Signed in with role admin/dev |
| `/dev/admins`, `/dev/audit`, `/dev/health`, `/dev/config` | dev | Role dev and aal2, else as above |

The guards are UX only: the database refuses everything the role can't do regardless.

---

## 7. Error codes

i18n key: `errors.<CODE>` in `web/src/i18n/{si,en}`. **Every code needs both languages** (`i18n:check` fails otherwise).

| Code | HTTP | Raised by | Meaning → what the UI says/does |
|---|---|---|---|
| `UNAUTHENTICATED` | 401 | functions, Edge | No/expired session → sign in again |
| `FORBIDDEN` | 403 | admin/dev functions, Edge | Role or MFA missing → admins: `/admin/mfa` |
| `ACCOUNT_SUSPENDED` | 403 | user writes, `create_order`, `resubmit_order` | Suspended by an admin → contact the organisers |
| `NOT_FOUND` | 404 | several | Missing, or not yours |
| `VALIDATION` | 400 | several, Edge (Zod) | Bad input → highlight the field |
| `PAYLOAD_TOO_LARGE` | 413 | Edge | Body over 16 KB |
| `PROFILE_INCOMPLETE` | 409 | `create_order` | Name or phone missing → profile step |
| `PHONE_TAKEN` | 409 | `update_my_profile` | Phone already registered |
| `ID_NUMBER_TAKEN` | 409 | `update_my_profile` | ID already registered |
| `SALES_CLOSED` | 409 | `create_order` | Outside the window, paused, or not configured |
| `CAPACITY_EXCEEDED` | 409 | `create_order` | Not enough seats → reduce tickets |
| `TOO_MANY_TICKETS_IN_ORDER` | 409 | `create_order` | Above `max_tickets_per_order` |
| `ACCOUNT_LIMIT` | 409 | `create_order` | Above `max_tickets_per_account` |
| `RATE_LIMITED` | 429 | `create_order` | More than 5 orders in an hour → wait |
| `DUPLICATE_RECEIPT` | 409 | `create_order`, `resubmit_order` | Same receipt file as a live order |
| `DUPLICATE_PAYMENT_REF` | 409 | `create_order`, `resubmit_order` | Same reference as a live order |
| `RECEIPT_INVALID` | 422 | Edge | Wrong type, > 5 MB, or bad path → re-upload |
| `UPLOAD_LIMIT` | — | client (from `my_upload_quota`) | 10 uploads in 24 h → try again tomorrow |
| `CAPTCHA_FAILED` | 400 | Edge | Turnstile failed → retry |
| `INVALID_TRANSITION` | 409 | review, cancel, resubmit, undo | State changed meanwhile → reload |
| `SELF_REVIEW_FORBIDDEN` | 403 | `approve_order`, `reject_order` | Own order → ask another admin |
| `REASON_TEXT_REQUIRED` | 400 | `reject_order`, `admin_undo_check_in`, `admin_set_status` | Reason needed |
| `HOLD_EXPIRED` | 409 | `resubmit_order` | Resubmit window closed → buy again |
| `RESUBMIT_LIMIT` | 409 | `resubmit_order` | Cap reached → contact the organisers |
| `INTERNAL` | 500 | anything unexpected | Show `Ref: <request_id>` |

---

## 8. Emails (D-08, D-09)

One outbox row per email (`notification_outbox`), deduplicated by `dedupe_key = '<kind>:<order_id>:<resubmit_count>'`.

| `kind` | When |
|---|---|
| `order_received` | order created |
| `order_resubmitted` | rejected order resubmitted |
| `order_approved` | approved (QR codes are now valid) |
| `order_rejected` | rejected; `reject.released` says whether seats were kept (resubmit possible) or released |
| `order_expired` | hold ran out |

`locale` is the buyer's; `to_email` the buyer's. `payload`:

```jsonc
{ "order_no": "ORD-…", "status": "submitted", "total_minor": 500000, "currency": "LKR", "buyer_name": "…",
  "event": { "name": "…", "venue": "…", "starts_at": "…" },
  "whatsapp_group_url": "https://chat.whatsapp.com/…" | null,
  "reject": null | { "code": "amount_mismatch", "label_en": "…", "label_si": "…", "note": "…" | null,
                     "hold_expires_at": "…" | null, "released": false },
  "tickets": [ { "seq": 1, "holder_name": "…", "short_code": "T-…", "status": "pending", "qr": "ST1.<uuid>.<mac>" } ] }
```

`qr` is a **bearer credential**: render it as a QR image in the email; never log it.

---

## 9. Where this overrides the spec

| Spec says | Now | Why |
|---|---|---|
| §9.2 resubmit deletes the old receipt; §12.4 orphans deleted after 24 h | **No receipt is deleted before the event**; all go in the R3 purge | SD-2: receipts are payment evidence |
| §10 mail via Resend/Brevo with our own domain | Gmail SMTP (465) with an App Password, separate senders for staging and prod | Decided 29 Oct (no domain); Edge→Gmail tested OK |
| §6.6 grants, §8.1 catalogue | Adds `set_my_locale`, `admin_set_status`, `my_upload_quota`; `reject_order` gains `p_release` | SD-1, SD-2, SD-5, SD-11 |
| Appendix A | Adds `ACCOUNT_SUSPENDED`, `UPLOAD_LIMIT`, `PAYLOAD_TOO_LARGE` | SD-4, SD-5, SD-2 |
| §6.7 / §9.1 / §12.4 receipts ≤ 2 MB | **≤ 5 MB per file** (migration 009); images still re-encoded to ~500 KB | Most buyers upload bank PDFs (decided 29 Oct) |
| §6.8 cron URL hard-coded | URL and secret from Vault, written by every deploy | SD-15 |
| §9.1 path check `startsWith` | Strict regex, enforced by Storage **and** the Edge Function | SD-4 |
