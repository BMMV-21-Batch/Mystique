#!/usr/bin/env bash
# D-14: restore a backup made by db-backup.sh into a database that already has the migrations.
# It REPLACES the data in the backed-up tables. Refuses to touch prod.
#
#   DB_HOST DB_PORT DB_USER PGPASSWORD  target connection (local stack or staging)
#   AGE_KEY_FILE                        private key (default ~/.config/mystique/backup-age-key.txt)
#   scripts/db-restore.sh <file.dump.age>
set -euo pipefail

in="${1:?usage: db-restore.sh <file.dump.age>}"
: "${DB_HOST:?}" "${DB_PORT:?}" "${DB_USER:?}" "${PGPASSWORD:?}"
key="${AGE_KEY_FILE:-$HOME/.config/mystique/backup-age-key.txt}"
[ -r "$key" ] || { echo "no private key at $key" >&2; exit 2; }

PROD_REF=ibhenicubyvvotlkefrh
case "$DB_USER" in *"$PROD_REF"*) echo "refusing to restore into prod" >&2; exit 2;; esac

PG_IMAGE=postgres:17.11-alpine
psql_() { docker run --rm -i --network host -e PGPASSWORD "$PG_IMAGE" \
            psql --host "$DB_HOST" --port "$DB_PORT" --username "$DB_USER" --dbname postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
decrypt() {
  if command -v age >/dev/null; then age -d -i "$key" "$in"
  else docker run --rm -i -v "$key:/k.txt:ro" alpine:3.20 sh -c 'apk add -q age >/dev/null 2>&1 && age -d -i /k.txt' < "$in"
  fi
}

# One transaction: empty the backed-up tables, load the dump. Replica mode skips triggers and
# FK checks (the audit guards, the new-user trigger) so rows load exactly as they were.
{
  echo "begin;"
  echo "set local session_replication_role = replica;"
  echo "delete from public.scan_log; delete from public.notification_outbox; delete from public.tickets;"
  echo "delete from public.orders; delete from public.audit_log; delete from public.event_config;"
  echo "delete from public.rejection_reasons; delete from public.profiles; delete from private.secrets;"
  echo "delete from storage.objects; delete from storage.buckets; delete from auth.identities; delete from auth.users;"
  decrypt | docker run --rm -i "$PG_IMAGE" pg_restore --data-only --no-owner --no-privileges --file -
  echo "commit;"
} | psql_

echo "restore finished into $DB_HOST"
