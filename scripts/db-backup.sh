#!/usr/bin/env bash
# D-14: encrypted, data-only backup of a Supabase database. Plain data never touches disk:
# pg_dump streams straight into age, encrypted to every key in scripts/backup-recipients.txt.
#
#   DB_HOST DB_PORT DB_USER PGPASSWORD  connection (pooler or local)
#   scripts/db-backup.sh <out-file.dump.age>
#
# What is dumped is what a restore onto a migrated database needs: all data in public and
# private (incl. the QR signing secret, without which every issued ticket stops scanning),
# auth users + identities, and storage metadata. Not dumped: schema (comes from migrations),
# Vault (rewritten by every deploy), receipt FILES (Storage, see spec §16.4).
set -euo pipefail

out="${1:?usage: db-backup.sh <out-file.dump.age>}"
here="$(cd "$(dirname "$0")" && pwd)"
: "${DB_HOST:?}" "${DB_PORT:?}" "${DB_USER:?}" "${PGPASSWORD:?}"

PG_IMAGE=postgres:17.11-alpine   # match the server's major version (17)

encrypt() {
  if command -v age >/dev/null; then age -R "$here/backup-recipients.txt"
  else docker run --rm -i -v "$here/backup-recipients.txt:/r.txt:ro" alpine:3.20 \
         sh -c 'apk add -q age >/dev/null 2>&1 && age -R /r.txt'
  fi
}

docker run --rm -i --network host -e PGPASSWORD "$PG_IMAGE" \
  pg_dump --host "$DB_HOST" --port "$DB_PORT" --username "$DB_USER" --dbname postgres \
    --data-only --format custom --no-owner --no-privileges \
    --table 'public.*' --table 'private.*' \
    --table auth.users --table auth.identities \
    --table storage.buckets --table storage.objects \
  | encrypt > "$out.partial"

# A truncated stream must never look like a good backup.
[ -s "$out.partial" ] || { echo "backup is empty" >&2; rm -f "$out.partial"; exit 1; }
mv "$out.partial" "$out"
echo "backup written: $out ($(wc -c < "$out") bytes, encrypted)"
