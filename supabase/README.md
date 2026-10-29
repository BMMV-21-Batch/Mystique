# supabase/

Owner: stream A (data & logic). Spec §6, §8, §9; work plan §4.1.

## migrations/

Applied in filename order. Spec §6 has the reference SQL. **Apply the spec-defect fixes (work plan §3) as you copy it.**

| File | Task | Content |
|---|---|---|
| `001_extensions_types.sql` | A-02 | Extensions, `private` schema, enums |
| `002_core_tables.sql` | A-03 | Tables, indexes, rejection reasons |
| `003_private_helpers.sql` | A-04 | Role checks, QR MAC, audit (+ TRUNCATE guard) |
| `004_functions_user.sql` | A-05 | User functions (+ `set_my_locale`) |
| `005_functions_admin_dev.sql` | A-06 | Admin/dev functions, views, analytics (+ `admin_set_status`, reject-and-release) |
| `006_rls_grants.sql` | A-07 | RLS, grants, default privileges |
| `007_storage.sql` | A-08 | Receipts bucket, 10 uploads/user/day |
| `008_cron.sql` | A-09 | Scheduled jobs (URL and secret from Vault) |

Create a new file with `pnpm exec supabase migration new <name>`, then rename it to follow the numbering. Never edit a migration that has already been applied to staging; add a new one instead.

## functions/

Deno Edge Functions. Shared code goes in `_shared/` (auth, CORS allowlist, Zod, error codes, logging, mail templates in `mail/`, email strings in `i18n/`).

| Function | Task | Auth |
|---|---|---|
| `submit-order` | B-08 | user JWT + Turnstile |
| `resubmit-order` | B-12 | user JWT (keeps the old receipt) |
| `send-notifications` | D-09 | cron secret |
| `health` | D-10 | public |
| `purge-event-data` | R11-05 | dev JWT + aal2 |

## tests/

pgTAP files (`*.test.sql`) run with `pnpm db:test`. Parallel-connection tests (T1, T2, T3, T7) go in `concurrency/` (A-15).
