-- A-12: spec §17.1 cases not already covered by the per-migration tests:
-- T5 (old QR version), T6 (reject cancelled, resubmit expired), T8 (resubmit after rejection with a new slip),
-- T9 (HOLD_EXPIRED), and the 5-orders-per-hour rate limit.
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

-- Start from empty tables whatever the seed loaded (rolled back at the end with everything else).
-- replica mode skips triggers, incl. the audit guards, for these deletes only.
set local session_replication_role = replica;
delete from public.scan_log; delete from public.notification_outbox; delete from public.tickets; delete from public.orders;
delete from public.audit_log; delete from public.event_config; delete from public.profiles; delete from auth.users;
delete from storage.objects where bucket_id = 'receipts';
set local session_replication_role = origin;

insert into public.event_config (name, starts_at, capacity, unit_price_minor, sales_open_at, sales_close_at, max_tickets_per_account)
values ('Party', now() + interval '30 days', 100, 1000, now() - interval '1 day', now() + interval '1 day', 50)
on conflict (id) do update set capacity = 1000, sales_paused = false, sales_open_at = now() - interval '1 day',
                               sales_close_at = now() + interval '1 day', max_tickets_per_account = 50;
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000f01', 'c1@example.com'),
  ('00000000-0000-0000-0000-000000000f02', 'c2@example.com'),
  ('00000000-0000-0000-0000-000000000fa1', 'ca@example.com');
update public.profiles set full_name = 'Case ' || right(id::text, 3)
 where id in ('00000000-0000-0000-0000-000000000f01', '00000000-0000-0000-0000-000000000f02');
update public.profiles set phone_e164 = '+94775550001' where id = '00000000-0000-0000-0000-000000000f01';
update public.profiles set phone_e164 = '+94775550002' where id = '00000000-0000-0000-0000-000000000f02';
update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-000000000fa1';

create function pg_temp.buy(buyer text, ref text, sha text) returns uuid language sql as $$
  select (public.create_order(buyer::uuid, gen_random_uuid(), '[{"name":"Case Holder"}]', 'Payer', null, ref,
          current_date, 'x/' || ref || '.jpg', rpad(sha, 64, '0'), 'image/jpeg', 1) ->> 'order_id')::uuid
$$;
create function pg_temp.resubmit(o uuid, ref text, sha text) returns jsonb language sql as $$
  select public.resubmit_order((select buyer_id from public.orders where id = o), o, 'Payer', null, ref,
                               current_date, 'x/' || ref || '-2.jpg', rpad(sha, 64, '0'), 'image/jpeg', 1)
$$;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000fa1","aal":"aal2"}', true);

-- T5: an old QR stops working once the ticket's qr_version is bumped
create temp table k as select pg_temp.buy('00000000-0000-0000-0000-000000000f01', 'CASE-T5', 'e1') as o;
select public.approve_order((select o from k));
create temp table qr_old as select private.qr_payload(id, qr_version) p, id from public.tickets where order_id = (select o from k);
update public.tickets set qr_version = qr_version + 1 where id = (select id from qr_old);
select is(public.check_in_ticket((select p from qr_old), 'G1') ->> 'result', 'invalid', 'T5: QR of an old version -> invalid');

-- T6: reject a cancelled order; resubmit an expired order
create temp table k6 as select pg_temp.buy('00000000-0000-0000-0000-000000000f02', 'CASE-T6', 'e2') as o;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000f02","aal":"aal1"}', true);
select public.cancel_my_order((select o from k6));
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000fa1","aal":"aal2"}', true);
select throws_ok(format($$ select public.reject_order(%L, 'amount_mismatch') $$, (select o from k6)),
                 'P0001', 'INVALID_TRANSITION', 'T6: rejecting a cancelled order -> INVALID_TRANSITION');

create temp table k9 as select pg_temp.buy('00000000-0000-0000-0000-000000000f02', 'CASE-T9', 'e3') as o;
select public.reject_order((select o from k9), 'payment_not_found');
update public.orders set hold_expires_at = now() - interval '1 minute' where id = (select o from k9);
select throws_ok(format($$ select pg_temp.resubmit(%L, 'CASE-T9B', 'e4') $$, (select o from k9)),
                 'P0001', 'HOLD_EXPIRED', 'T9: resubmit after the hold ran out -> HOLD_EXPIRED');
select public.expire_stale_orders();
select throws_ok(format($$ select pg_temp.resubmit(%L, 'CASE-T9B', 'e4') $$, (select o from k9)),
                 'P0001', 'INVALID_TRANSITION', 'T6: resubmitting an expired order -> INVALID_TRANSITION');

-- T8: duplicates block while live; after rejection the buyer resubmits with a new slip
create temp table k8 as select pg_temp.buy('00000000-0000-0000-0000-000000000f01', 'CASE-T8', 'e5') as o;
select throws_ok($$ select pg_temp.buy('00000000-0000-0000-0000-000000000f02', 'CASE-T8', 'e6') $$,
                 'P0001', 'DUPLICATE_PAYMENT_REF', 'T8: same reference on a second live order');
select public.reject_order((select o from k8), 'receipt_unreadable');
select lives_ok($$ select pg_temp.buy('00000000-0000-0000-0000-000000000f02', 'CASE-T8', 'e6') $$,
                'T8: once rejected, the reference is free for another order');
select throws_ok(format($$ select pg_temp.resubmit(%L, 'CASE-T8', 'e7') $$, (select o from k8)),
                 'P0001', 'DUPLICATE_PAYMENT_REF', 'T8: resubmitting with a reference now live elsewhere is refused');
select is(pg_temp.resubmit((select o from k8), 'CASE-T8-NEW', 'e8') ->> 'status', 'submitted',
          'T8: resubmission with a different slip works');

-- Rate limit: at most 5 orders per buyer per hour (k5/k8 already used 2 of c1's)
select pg_temp.buy('00000000-0000-0000-0000-000000000f01', 'CASE-RL' || i, 'f' || i) from generate_series(1, 3) i;
select throws_ok($$ select pg_temp.buy('00000000-0000-0000-0000-000000000f01', 'CASE-RL9', 'f9') $$,
                 'P0001', 'RATE_LIMITED', 'sixth order within an hour -> RATE_LIMITED');

select * from finish();
rollback;
