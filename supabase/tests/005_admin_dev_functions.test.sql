-- Migration 005: config (SD-19), review incl. reject-and-release (SD-1), expiry, check-in (T4-T6, SD-13),
-- offline (SD-12), suspension (SD-5), admin grants, views (SD-10, SD-17), analytics, health, outbox worker.
begin;
create extension if not exists pgtap with schema extensions;
select plan(70);

-- Start from empty tables whatever the seed loaded (rolled back at the end with everything else).
-- replica mode skips triggers, incl. the audit guards, for these deletes only.
set local session_replication_role = replica;
delete from public.scan_log; delete from public.notification_outbox; delete from public.tickets; delete from public.orders;
delete from public.audit_log; delete from public.event_config; delete from public.profiles; delete from auth.users;
delete from storage.objects where bucket_id = 'receipts';
set local session_replication_role = origin;

-- Fixtures ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000c01', 'b1@example.com'),
  ('00000000-0000-0000-0000-000000000c02', 'b2@example.com'),
  ('00000000-0000-0000-0000-000000000ca1', 'a1@example.com'),
  ('00000000-0000-0000-0000-000000000ca2', 'a2@example.com'),
  ('00000000-0000-0000-0000-000000000cd1', 'd1@example.com');
update public.profiles set full_name = 'Person ' || right(id::text, 3)
 where id::text like '00000000-0000-0000-0000-000000000c%';
update public.profiles set phone_e164 = '+94770000001' where id = '00000000-0000-0000-0000-000000000c01';
update public.profiles set phone_e164 = '+94770000002' where id = '00000000-0000-0000-0000-000000000c02';
update public.profiles set phone_e164 = '+94770001001' where id = '00000000-0000-0000-0000-000000000ca1';
update public.profiles set phone_e164 = '+94770001002' where id = '00000000-0000-0000-0000-000000000ca2';
update public.profiles set phone_e164 = '+94770001003' where id = '00000000-0000-0000-0000-000000000cd1';
update public.profiles set role = 'admin', staff_code = 'A901' where id = '00000000-0000-0000-0000-000000000ca1';
update public.profiles set role = 'admin', staff_code = 'A902' where id = '00000000-0000-0000-0000-000000000ca2';
update public.profiles set role = 'dev',   staff_code = 'D901' where id = '00000000-0000-0000-0000-000000000cd1';

create function pg_temp.as_user(uid text, aal text default 'aal2') returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'aal', aal)::text, true)
$$;
create temp table ord (k text primary key, id uuid);
create function pg_temp.buy(k text, buyer text, n int) returns uuid language sql as $$
  insert into ord values (k, (public.create_order(buyer::uuid, gen_random_uuid(),
           (select jsonb_agg(jsonb_build_object('name', 'Holder ' || i)) from generate_series(1, n) i),
           'Payer', 'BOC', 'REF-' || k, current_date, buyer || '/' || k || '.jpg', rpad(md5(k), 64, '0'), 'image/jpeg', 1000)
         ->> 'order_id')::uuid)
  returning id
$$;
create function pg_temp.o(k text) returns uuid language sql as $$ select id from ord where ord.k = $1 $$;
create function pg_temp.qr(k text, s int) returns text language sql as $$
  select private.qr_payload(t.id, t.qr_version) from public.tickets t where t.order_id = pg_temp.o(k) and t.seq = s
$$;

-- Event config (SD-19) -----------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000000ca1');
select throws_ok($$ select public.dev_update_event_config('{"name":"x"}') $$, 'P0001', 'FORBIDDEN', 'admin cannot edit config');
select pg_temp.as_user('00000000-0000-0000-0000-000000000cd1', 'aal1');
select throws_ok($$ select public.dev_update_event_config('{"name":"x"}') $$, 'P0001', 'FORBIDDEN', 'dev at aal1 cannot edit config');

select pg_temp.as_user('00000000-0000-0000-0000-000000000cd1');
select lives_ok(format($$ select public.dev_update_event_config(%L) $$, jsonb_build_object(
  'name', 'Party', 'starts_at', now() + interval '30 days', 'capacity', 10, 'unit_price_minor', 100000,
  'sales_open_at', now() - interval '1 day', 'sales_close_at', now() + interval '1 day',
  'max_tickets_per_order', 4, 'max_tickets_per_account', 10,
  'whatsapp_group_url', 'https://chat.whatsapp.com/Abc123')), 'dev creates the config row on first setup');
select is((select count(*)::int from public.event_config), 1, 'exactly one config row');
select throws_ok(format($$ select public.dev_update_event_config(%L) $$, jsonb_build_object('sales_close_at', now() - interval '2 days')),
                 'P0001', 'VALIDATION', 'close before open -> VALIDATION');
select throws_ok($$ select public.dev_update_event_config('{"capacity":"abc"}') $$, 'P0001', 'VALIDATION', 'non-numeric capacity -> VALIDATION');
select throws_ok($$ select public.dev_update_event_config('{"whatsapp_group_url":"http://evil.example"}') $$,
                 'P0001', 'VALIDATION', 'non-WhatsApp URL -> VALIDATION');
select public.dev_update_event_config('{"rejected_hold_minutes":60,"max_resubmits":1}');
select results_eq($$ select rejected_hold_minutes, max_resubmits from public.event_config $$, $$ values (60, 1) $$,
                  'hold minutes and resubmit limit are editable (SD-19)');
select public.dev_update_event_config('{"name":"Party 2"}');
select is((select whatsapp_group_url from public.event_config), 'https://chat.whatsapp.com/Abc123', 'absent key keeps the URL');
select public.dev_update_event_config('{"whatsapp_group_url":null}');
select is((select whatsapp_group_url from public.event_config), null, 'explicit null clears the URL (SD-19)');
select public.dev_update_event_config('{"whatsapp_group_url":"https://chat.whatsapp.com/Abc123"}');

-- Orders ------------------------------------------------------------------------
select pg_temp.buy('o1', '00000000-0000-0000-0000-000000000c01', 2);
select pg_temp.buy('o2', '00000000-0000-0000-0000-000000000c01', 2);
select pg_temp.buy('o3', '00000000-0000-0000-0000-000000000c02', 2);
select pg_temp.buy('o4', '00000000-0000-0000-0000-000000000c02', 1);
select pg_temp.buy('o5', '00000000-0000-0000-0000-000000000ca1', 1);   -- an admin's own order

-- Approve ---------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000000c01');
select throws_ok(format($$ select public.approve_order(%L) $$, pg_temp.o('o1')), 'P0001', 'FORBIDDEN', 'user cannot approve');
select pg_temp.as_user('00000000-0000-0000-0000-000000000ca1', 'aal1');
select throws_ok(format($$ select public.approve_order(%L) $$, pg_temp.o('o1')), 'P0001', 'FORBIDDEN', 'admin without MFA cannot approve');
select pg_temp.as_user('00000000-0000-0000-0000-000000000ca1');
select throws_ok(format($$ select public.approve_order(%L) $$, pg_temp.o('o5')), 'P0001', 'SELF_REVIEW_FORBIDDEN', 'four-eyes: no self review');
select is((public.approve_order(pg_temp.o('o1'), '  Thanks! ')).status::text, 'approved', 'admin approves');
select is((select count(*)::int from public.tickets where order_id = pg_temp.o('o1') and status = 'valid'), 2, 'approved tickets are valid');
select is((select count(*)::int from public.notification_outbox where kind = 'order_approved'), 1, 'approval email queued');
select throws_ok(format($$ select public.approve_order(%L) $$, pg_temp.o('o1')), 'P0001', 'INVALID_TRANSITION', 'second review loses (T7 shape)');
select results_eq(format($$ select reviewer_code, review_note from public.admin_orders_v where id = %L $$, pg_temp.o('o1')),
                  $$ values ('A901', 'Thanks!') $$, 'reviewer staff code and trimmed buyer note');

-- Reject (hold) and reject-and-release (SD-1) ------------------------------------
select throws_ok(format($$ select public.reject_order(%L, 'other') $$, pg_temp.o('o2')), 'P0001', 'REASON_TEXT_REQUIRED', '"other" needs text');
select throws_ok(format($$ select public.reject_order(%L, 'nope') $$, pg_temp.o('o2')), 'P0001', 'VALIDATION', 'unknown reason -> VALIDATION');
select public.reject_order(pg_temp.o('o2'), 'amount_mismatch');
select ok((select status = 'rejected' and hold_expires_at between now() + interval '59 minutes' and now() + interval '61 minutes'
           from public.orders where id = pg_temp.o('o2')), 'rejected with the configured hold');
select is((select count(*)::int from public.tickets where order_id = pg_temp.o('o2') and status = 'pending'), 2, 'held seats stay pending');
select is((select payload -> 'reject' ->> 'released' from public.notification_outbox where kind = 'order_rejected'),
          'false', 'rejection email says seats are held');

select public.reject_order(pg_temp.o('o3'), 'payment_not_found', null, true);
select results_eq(format($$ select status::text, reject_reason_code, hold_expires_at from public.orders where id = %L $$, pg_temp.o('o3')),
                  $$ values ('expired', 'payment_not_found', null::timestamptz) $$, 'reject-and-release ends the order now (SD-1)');
select is((select count(*)::int from public.tickets where order_id = pg_temp.o('o3') and status = 'void'), 2, 'released tickets are void');
select is((select count(*)::int from public.tickets where status <> 'void'), 6, 'released seats are free again');
select is((select payload -> 'reject' ->> 'released' from public.notification_outbox
           where kind = 'order_rejected' and payload ->> 'order_no' = (select order_no from public.orders where id = pg_temp.o('o3'))),
          'true', 'release email still carries the reason');
select is((select meta ->> 'release' from public.audit_log where action = 'order.reject' and entity_id = pg_temp.o('o3')::text),
          'true', 'release is audited');

-- Expiry ------------------------------------------------------------------------
update public.orders set hold_expires_at = now() - interval '1 minute' where id = pg_temp.o('o2');
select is(public.expire_stale_orders(), 1, 'one stale rejected order expired');
select is((select count(*)::int from public.tickets where order_id = pg_temp.o('o2') and status = 'void'), 2, 'expired order releases its seats');

-- Check-in (T4, T5, T6, SD-13) ---------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000000ca2');
select public.approve_order(pg_temp.o('o4'));
select pg_temp.as_user('00000000-0000-0000-0000-000000000c01');
select throws_ok(format($$ select public.check_in_ticket(%L, 'G1') $$, pg_temp.qr('o1', 1)), 'P0001', 'FORBIDDEN', 'user cannot scan');
select pg_temp.as_user('00000000-0000-0000-0000-000000000ca1');
select is(public.check_in_ticket('garbage', 'G1') ->> 'result', 'invalid', 'garbage -> invalid');
select is(public.check_in_ticket('ST1.' || repeat('-', 36) || '.' || repeat('A', 22), 'G1') ->> 'result', 'invalid',
          '36 dashes -> invalid, not an exception (SD-13)');
select is(public.check_in_ticket(left(pg_temp.qr('o1', 1), -22) || repeat('A', 22), 'G1') ->> 'result', 'invalid', 'forged MAC -> invalid');
select is(public.check_in_ticket(pg_temp.qr('o5', 1), 'G1') ->> 'result', 'waiting_approval', 'pending ticket -> waiting_approval');
select is(public.check_in_ticket(pg_temp.qr('o1', 1), 'G1') ->> 'result', 'ok', 'valid ticket -> ok');
select is(public.check_in_ticket(pg_temp.qr('o1', 1), 'G2') ->> 'result', 'already_used', 'second scan -> already_used');
select is(public.check_in_ticket(pg_temp.qr('o3', 1), 'G1') ->> 'result', 'void', 'released ticket -> void');
select is((select count(*)::int from public.scan_log), 7, 'every scan is logged');

select throws_ok(format($$ select public.admin_undo_check_in(%L, 'x') $$, (select id from public.tickets where order_id = pg_temp.o('o1') and seq = 1)),
                 'P0001', 'REASON_TEXT_REQUIRED', 'undo needs a reason');
select public.admin_undo_check_in((select id from public.tickets where order_id = pg_temp.o('o1') and seq = 1), 'wrong person scanned');
select is(public.check_in_ticket(pg_temp.qr('o1', 1), 'G1') ->> 'result', 'ok', 'after undo the ticket checks in again');
select throws_ok(format($$ select public.admin_undo_check_in(%L, 'mistake') $$, (select id from public.tickets where order_id = pg_temp.o('o1') and seq = 2)),
                 'P0001', 'INVALID_TRANSITION', 'cannot undo an unused ticket');

-- Offline (P1, SD-12) ---------------------------------------------------------------
select is((select jsonb_agg(x ->> 'result') from jsonb_array_elements(public.sync_offline_scans(jsonb_build_array(
             jsonb_build_object('payload', pg_temp.qr('o1', 2), 'gate', 'G3', 'scanned_at', now() - interval '5 minutes'),
             jsonb_build_object('payload', pg_temp.qr('o1', 2), 'gate', 'G3', 'scanned_at', 'not-a-time')))) x),
          '["ok", "already_used"]'::jsonb, 'offline batch: first ok, duplicate already_used, bad time tolerated');
select throws_ok($$ select public.sync_offline_scans('{}') $$, 'P0001', 'VALIDATION', 'offline batch must be an array');
select is((select provolatile::text from pg_proc where oid = 'public.scanner_manifest()'::regprocedure), 'v', 'scanner_manifest is VOLATILE (SD-12)');
select is((select count(*)::int from public.scanner_manifest()), 4, 'manifest lists the non-void tickets');
select is((select count(*)::int from public.audit_log where action = 'scanner.manifest_export'), 1, 'manifest export is audited');

-- WhatsApp tracking ----------------------------------------------------------------
select public.mark_whatsapp_added('00000000-0000-0000-0000-000000000c01', true);
select is((select whatsapp_added_by from public.profiles where id = '00000000-0000-0000-0000-000000000c01'),
          '00000000-0000-0000-0000-000000000ca1'::uuid, 'WhatsApp membership recorded with the admin');
select throws_ok($$ select public.mark_whatsapp_added(gen_random_uuid(), true) $$, 'P0001', 'NOT_FOUND', 'unknown user -> NOT_FOUND');

-- Views (SD-10, SD-17) --------------------------------------------------------------
select results_eq($$ select orders, tickets, paid_minor from public.admin_users_v where id = '00000000-0000-0000-0000-000000000c01' $$,
                  $$ values (2::bigint, 2::bigint, 200000::bigint) $$, 'paid total is not multiplied by ticket count (SD-10)');
select is((select holder_names from public.admin_orders_v where id = pg_temp.o('o1')), 'Holder 1, Holder 2',
          'orders view exposes holder names for search (SD-17)');

-- Suspension (SD-5) -----------------------------------------------------------------
select throws_ok($$ select public.admin_set_status('00000000-0000-0000-0000-000000000ca1', 'suspended', 'test me') $$,
                 'P0001', 'FORBIDDEN', 'admin cannot suspend themselves');
select throws_ok($$ select public.admin_set_status('00000000-0000-0000-0000-000000000cd1', 'suspended', 'test me') $$,
                 'P0001', 'FORBIDDEN', 'admin cannot suspend a dev');
select throws_ok($$ select public.admin_set_status('00000000-0000-0000-0000-000000000ca2', 'suspended', 'test me') $$,
                 'P0001', 'FORBIDDEN', 'admin cannot suspend another admin');
select throws_ok($$ select public.admin_set_status('00000000-0000-0000-0000-000000000c02', 'suspended', 'x') $$,
                 'P0001', 'REASON_TEXT_REQUIRED', 'suspension needs a reason');
select public.admin_set_status('00000000-0000-0000-0000-000000000c02', 'suspended', 'seat griefing');
select is((select count(*)::int from public.audit_log where action = 'user.suspend'), 1, 'suspension is audited');
select throws_ok($$ select pg_temp.buy('o6', '00000000-0000-0000-0000-000000000c02', 1) $$,
                 'P0001', 'ACCOUNT_SUSPENDED', 'suspended user cannot buy');
select public.admin_set_status('00000000-0000-0000-0000-000000000c02', 'active', 'appeal accepted');
select is((select status::text from public.profiles where id = '00000000-0000-0000-0000-000000000c02'), 'active', 'admin reactivates a user');

select pg_temp.as_user('00000000-0000-0000-0000-000000000cd1');
select public.admin_set_status('00000000-0000-0000-0000-000000000ca2', 'suspended', 'lost phone');
select pg_temp.as_user('00000000-0000-0000-0000-000000000ca2');
select throws_ok(format($$ select public.approve_order(%L) $$, pg_temp.o('o5')), 'P0001', 'FORBIDDEN',
                 'suspended admin is locked out on the next request');
select pg_temp.as_user('00000000-0000-0000-0000-000000000cd1');
select public.admin_set_status('00000000-0000-0000-0000-000000000ca2', 'active', 'phone recovered');

-- Admin grants -----------------------------------------------------------------------
select throws_ok($$ select public.dev_set_admin('00000000-0000-0000-0000-000000000cd1', true) $$, 'P0001', 'FORBIDDEN', 'dev cannot change own role');
select public.dev_set_admin('00000000-0000-0000-0000-000000000c01', true);
select matches((select role::text || ' ' || staff_code from public.profiles where id = '00000000-0000-0000-0000-000000000c01'),
               '^admin A[0-9]{3}$', 'dev grants admin with a staff code');
select public.dev_set_admin('00000000-0000-0000-0000-000000000c01', false);
select ok((select role = 'user' and staff_code is not null from public.profiles where id = '00000000-0000-0000-0000-000000000c01'),
          'revoke keeps the staff code for audit continuity');
select pg_temp.as_user('00000000-0000-0000-0000-000000000ca1');
select throws_ok($$ select public.dev_set_admin('00000000-0000-0000-0000-000000000c02', true) $$, 'P0001', 'FORBIDDEN', 'admin cannot grant admin');

-- Analytics and health ----------------------------------------------------------------
select is((public.admin_analytics() ->> 'capacity')::int, 10, 'admin sees analytics');
select throws_ok($$ select public.dev_health() $$, 'P0001', 'FORBIDDEN', 'admin cannot see dev health');
select pg_temp.as_user('00000000-0000-0000-0000-000000000c01');
select throws_ok($$ select public.admin_analytics() $$, 'P0001', 'FORBIDDEN', 'user cannot see analytics');
select pg_temp.as_user('00000000-0000-0000-0000-000000000cd1');
select ok(public.dev_health() ?& array['outbox', 'receipt_objects', 'top_uploaders', 'cron_last_runs'], 'dev health has every section');

-- Outbox worker ---------------------------------------------------------------------
select is((select count(*)::int from public.claim_notifications(100)),
          (select count(*)::int from public.notification_outbox), 'worker claims every due email');
select is((select count(*)::int from public.notification_outbox where status <> 'sending'), 0, 'claimed emails are marked sending');
select public.mark_notification((select min(id) from public.notification_outbox), true);
select public.mark_notification((select max(id) from public.notification_outbox), false, 'smtp 421');
select results_eq($$ select status::text, next_attempt_at > now() from public.notification_outbox
                     where id in ((select min(id) from public.notification_outbox), (select max(id) from public.notification_outbox)) order by id $$,
                  $$ values ('sent', true), ('failed', true) $$, 'sent and failed (with back-off) are recorded');

select * from finish();
rollback;
