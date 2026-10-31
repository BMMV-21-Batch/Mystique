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

### Per-environment setup (once, never committed)

- **QR signing secret:** created automatically by `003` inside each database. Never change it: that invalidates every issued QR.
- **Cron → `send-notifications`:** set a `CRON_SECRET` GitHub secret in each environment, once:
  ```bash
  openssl rand -hex 32 | gh secret set CRON_SECRET --env staging     # and again (new value) --env production
  ```
  Every deploy then writes the Vault entries `notify_url` + `cron_secret` (`scripts/supabase-vault-config.mjs`)
  and gives the same value to the Edge Functions, so they always match. Don't create them by hand in the
  dashboard (the comment in `008` predates this); to rotate, set a new GitHub secret and redeploy.
  Until it is set, the outbox drain job does nothing (no errors) and emails wait in the outbox.

### Backups (D-14)

- **Nightly** (`backup.yml`, 02:00 Colombo, or run it by hand from the Actions tab) and **before every prod migration** (`deploy.yml`): a data-only dump of prod, `age`-encrypted to the keys in `scripts/backup-recipients.txt`, kept as an artifact for 7 / 30 days.
- **Private keys** are held offline by their owners (default path `~/.config/mystique/backup-age-key.txt`). Without one, a backup cannot be read. Keep a copy in a password manager.
- **Restore** (local stack or staging only; the script refuses prod):
  ```bash
  gh run download <run-id> --repo BMMV-21-Batch/Mystique     # get the .dump.age artifact
  DB_HOST=127.0.0.1 DB_PORT=54322 DB_USER=postgres PGPASSWORD=postgres scripts/db-restore.sh prod-….dump.age
  ```
  For staging: `DB_HOST=aws-0-ap-southeast-1.pooler.supabase.com DB_PORT=5432 DB_USER=postgres.<staging-ref>`.
  Restoring INTO prod after a disaster is deliberately not scripted: do it by hand with the release lead.
- Not in the dump: receipt **files** (export Storage manually at close of sales, spec §16.4), and Vault (rewritten by every deploy).

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
