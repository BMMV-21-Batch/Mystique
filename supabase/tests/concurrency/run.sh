#!/usr/bin/env bash
# A-15 / SD-20: race tests that need truly parallel connections (pgTAP runs in one transaction).
#   T1 oversell        40 buyers race for the last 20 seats       -> exactly 20 orders, 0 oversold
#   T2 idempotency     10 parallel retries with one key            -> exactly 1 order
#   T3 double check-in 10 gates scan the same ticket at once        -> exactly 1 'ok'
#   T7 two reviewers   approve vs reject on the same order, x10     -> exactly 1 winner per order
#
# Runs against the LOCAL stack only (refuses anything else). Leaves no data behind except
# audit rows (append-only by design). Usage: supabase/tests/concurrency/run.sh
set -euo pipefail

DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
case "$DB_URL" in *@127.0.0.1:*|*@localhost:*) ;; *) echo "refusing to run against a non-local database" >&2; exit 2;; esac

if command -v psql >/dev/null; then
  q() { psql "$DB_URL" -X -q -tA -v ON_ERROR_STOP=1 "$@"; }
else  # no local psql: use the one inside the database container
  DB_CONTAINER="${DB_CONTAINER:-$(docker ps --format '{{.Names}}' | grep -m1 '^supabase_db_')}"
  q() { docker exec -i "$DB_CONTAINER" psql -U postgres -X -q -tA -v ON_ERROR_STOP=1 "$@"; }
fi

WORK="$(mktemp -d)"; trap 'cleanup; rm -rf "$WORK"' EXIT
fail=0
check() {  # check <name> <actual> <expected>
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (got $2, want $3)"; fail=1; fi
}
# Fire N copies of a SQL snippet at the same instant. {i} in the SQL is replaced by 1..N.
race() {  # race <label> <n> <sql>
  local start; start="$(q -c "select (now() + interval '1500 ms')::text")"
  for i in $(seq 1 "$2"); do
    (q -c "select pg_sleep_until('$start'); ${3//\{i\}/$i}" >"$WORK/$1.$i.out" 2>&1 || true) &
  done
  wait
}
count() { cat "$WORK/$1".*.out | grep -c -- "$2" || true; }

cleanup() {
  q >/dev/null 2>&1 <<'SQL' || true
    delete from public.scan_log where ticket_id in (select t.id from public.tickets t join public.profiles p on p.id = t.buyer_id where p.email like 'conc-%@test.local');
    delete from public.notification_outbox where to_email like 'conc-%@test.local';
    delete from public.orders where buyer_id in (select id from public.profiles where email like 'conc-%@test.local');
    delete from public.profiles where email like 'conc-%@test.local';
    delete from auth.users where email like 'conc-%@test.local';
    update public.event_config c set capacity = s.capacity, sales_paused = s.sales_paused,
           sales_open_at = s.sales_open_at, sales_close_at = s.sales_close_at,
           max_tickets_per_account = s.max_tickets_per_account
      from conc_saved_config s where c.id = true;
    drop table if exists conc_saved_config;
SQL
}

# Setup ---------------------------------------------------------------------------------
cleanup
q <<'SQL'
  create table conc_saved_config as select * from public.event_config where id = true;
  insert into auth.users (id, email)
    select gen_random_uuid(), 'conc-u' || i || '@test.local' from generate_series(1, 40) i
    union all select gen_random_uuid(), 'conc-a' || i || '@test.local' from generate_series(1, 2) i;
  update public.profiles set full_name = 'Racer ' || split_part(email, '@', 1) where email like 'conc-%@test.local';
SQL
q -c "update public.profiles p set phone_e164 = '+9479' || lpad(x.n::text, 8, '0')
        from (select id, row_number() over (order by email) n from public.profiles where email like 'conc-%@test.local') x
       where p.id = x.id" \
  -c "update public.profiles set role = 'admin' where email like 'conc-a%@test.local'"
# Leave exactly 20 seats free, whatever the seed holds.
q -c "update public.event_config set sales_paused = false, sales_open_at = now() - interval '1 day',
        sales_close_at = now() + interval '1 day', max_tickets_per_account = 20,
        capacity = (select count(*) from public.tickets where status <> 'void') + 20"

uid() { q -c "select id from public.profiles where email = '$1'"; }
ADMIN() { echo "select set_config('request.jwt.claims', json_build_object('sub', (select id from public.profiles where email = 'conc-a$1@test.local'), 'aal', 'aal2')::text, false);"; }

# T1 oversell ---------------------------------------------------------------------------
race t1 40 "select public.create_order((select id from public.profiles where email = 'conc-u{i}@test.local'), gen_random_uuid(),
             '[{\"name\":\"Racer {i}\"}]', 'Racer', null, 'CONC-T1-{i}', null, 'x/{i}.jpg', md5('t1-{i}') || md5('t1-{i}'), 'image/jpeg', 1);"
check "T1: 20 of 40 racing buyers get a seat" "$(count t1 '"replayed": false')" 20
check "T1: the other 20 get CAPACITY_EXCEEDED" "$(count t1 CAPACITY_EXCEEDED)" 20
check "T1: no oversell (free seats left = 0)" \
  "$(q -c "select capacity - (select count(*) from public.tickets where status <> 'void') from public.event_config")" 0

# T2 idempotency ------------------------------------------------------------------------
q -c "update public.event_config set capacity = capacity + 5"
U1="$(uid conc-u1@test.local)"; KEY="$(q -c 'select gen_random_uuid()')"
race t2 10 "select public.create_order('$U1', '$KEY', '[{\"name\":\"Retry Racer\"}]', 'Racer', null, 'CONC-T2', null,
             'x/t2.jpg', md5('t2') || md5('t2'), 'image/jpeg', 1);"
check "T2: 10 parallel retries create exactly 1 order" \
  "$(q -c "select count(*) from public.orders where buyer_id = '$U1' and idempotency_key = '$KEY'")" 1
check "T2: the other 9 see a replay" "$(count t2 '"replayed": true')" 9

# T3 double check-in --------------------------------------------------------------------
ORDER="$(q -c "select id from public.orders where payment_ref = 'CONCT2'")"
q -c "$(ADMIN 1) select public.approve_order('$ORDER');" >/dev/null
PAYLOAD="$(q -c "select private.qr_payload(id, qr_version) from public.tickets where order_id = '$ORDER'")"
race t3 10 "$(ADMIN 2) select public.check_in_ticket('$PAYLOAD', 'gate-{i}');"
check "T3: exactly 1 of 10 simultaneous scans is ok" "$(count t3 '"result": "ok"')" 1
check "T3: the other 9 are already_used" "$(count t3 '"result": "already_used"')" 9

# T7 two reviewers ----------------------------------------------------------------------
mapfile -t ORDERS < <(q -c "select id from public.orders where status = 'submitted' and payment_ref like 'CONCT1%' order by payment_ref limit 10")
for o in "${ORDERS[@]}"; do
  start="$(q -c "select (now() + interval '500 ms')::text")"
  (q -c "select pg_sleep_until('$start'); $(ADMIN 1) select (public.approve_order('$o')).status;" >"$WORK/t7.$o.a.out" 2>&1 || true) &
  (q -c "select pg_sleep_until('$start'); $(ADMIN 2) select (public.reject_order('$o', 'amount_mismatch')).status;" >"$WORK/t7.$o.r.out" 2>&1 || true) &
  wait
done
check "T7: 10 orders, one review wins each" "$(( $(count t7 approved) + $(count t7 rejected) ))" 10
check "T7: the 10 losers get INVALID_TRANSITION" "$(count t7 INVALID_TRANSITION)" 10
check "T7: each order has exactly one review in the audit log" \
  "$(q -c "select count(*) from (select entity_id from public.audit_log where action in ('order.approve', 'order.reject')
           and entity_id in ($(printf "'%s'," "${ORDERS[@]}" | sed 's/,$//')) group by entity_id having count(*) = 1) x")" 10

if [ "$fail" -ne 0 ]; then echo "concurrency tests FAILED"; exit 1; fi
echo "all concurrency tests passed"
