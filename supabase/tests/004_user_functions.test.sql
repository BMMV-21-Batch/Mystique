-- Migration 004: profile, locale (SD-11), orders incl. validation mapping (SD-14) and suspension (SD-5).
begin;
create extension if not exists pgtap with schema extensions;
select plan(41);

-- Fixtures ---------------------------------------------------------------------
insert into public.event_config (name, starts_at, capacity, unit_price_minor, sales_open_at, sales_close_at,
                                 max_tickets_per_order, max_tickets_per_account, whatsapp_group_url, bank_details)
values ('Test party', now() + interval '30 days', 10, 150000, now() - interval '1 day', now() + interval '1 day',
        4, 6, 'https://chat.whatsapp.com/AbC123', '{"bank":"Test Bank"}');

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000b01', 'u1@example.com'),
  ('00000000-0000-0000-0000-000000000b02', 'u2@example.com'),
  ('00000000-0000-0000-0000-000000000b03', 'u3@example.com'),   -- incomplete profile
  ('00000000-0000-0000-0000-000000000b04', 'u4@example.com');   -- suspended

create function pg_temp.as_user(uid text) returns void language sql as $$
  select set_config('request.jwt.claims',
                    case when uid is null then '' else json_build_object('sub', uid, 'aal', 'aal1')::text end, true)
$$;
-- create_order with generated holders; ref and receipt hash are per call
create function pg_temp.buy(buyer text, n int, ref text, sha text, idem uuid default gen_random_uuid(),
                            holder text default 'Holder') returns jsonb language sql as $$
  select public.create_order(buyer::uuid, idem,
           (select jsonb_agg(jsonb_build_object('name', holder || ' ' || i)) from generate_series(1, n) i),
           'Payer Name', 'BOC', ref, current_date, buyer || '/r.jpg', rpad(sha, 64, '0'), 'image/jpeg', 1000)
$$;

-- Profile ------------------------------------------------------------------------
select pg_temp.as_user(null);
select throws_ok($$ select public.update_my_profile('A', '+94771234567', null, null, 'en') $$,
                 'P0001', 'UNAUTHENTICATED', 'profile update needs a session');

select pg_temp.as_user('00000000-0000-0000-0000-000000000b01');
select public.update_my_profile('  Kamal Perera ', '+94771111111', null, null, 'en');
select results_eq($$ select full_name, whatsapp_e164 from public.profiles where id = '00000000-0000-0000-0000-000000000b01' $$,
                  $$ values ('Kamal Perera', '+94771111111') $$, 'profile saved, name trimmed, WhatsApp defaults to phone');

select public.set_my_locale('si');
select results_eq($$ select locale, full_name, phone_e164 from public.profiles where id = '00000000-0000-0000-0000-000000000b01' $$,
                  $$ values ('si', 'Kamal Perera', '+94771111111') $$, 'set_my_locale changes only the locale (SD-11)');
select throws_ok($$ select public.set_my_locale('fr') $$, 'P0001', 'VALIDATION', 'set_my_locale rejects unknown locales');

select pg_temp.as_user('00000000-0000-0000-0000-000000000b02');
select throws_ok($$ select public.update_my_profile('Nimal', '+94771111111', null, null, 'en') $$,
                 'P0001', 'PHONE_TAKEN', 'duplicate phone -> PHONE_TAKEN');
select throws_ok($$ select public.update_my_profile('Nimal', 'not-a-phone', null, null, 'en') $$,
                 'P0001', 'VALIDATION', 'bad phone -> VALIDATION');
select public.update_my_profile('Nimal Silva', '+94772222222', null, null, 'en');

select pg_temp.as_user('00000000-0000-0000-0000-000000000b04');
select public.update_my_profile('Sunil', '+94774444444', null, null, 'en');
update public.profiles set status = 'suspended' where id = '00000000-0000-0000-0000-000000000b04';
select throws_ok($$ select public.update_my_profile('Sunil', '+94774444444', null, null, 'en') $$,
                 'P0001', 'ACCOUNT_SUSPENDED', 'suspended user cannot edit profile (SD-5)');
select lives_ok($$ select public.set_my_locale('si') $$, 'suspended user can still switch language');

select pg_temp.as_user('00000000-0000-0000-0000-000000000b03');
select public.request_admin_access();
select isnt((select admin_requested_at from public.profiles where id = '00000000-0000-0000-0000-000000000b03'),
            null, 'request_admin_access sets admin_requested_at');
select is((select count(*)::int from public.audit_log where action = 'admin.request'), 1, 'admin request is audited');

-- create_order: happy path -------------------------------------------------------
select pg_temp.as_user(null);
select is((pg_temp.buy('00000000-0000-0000-0000-000000000b01', 2, 'ref-1001', 'a1',
                       '00000000-0000-0000-0000-00000000aaaa') ->> 'replayed'), 'false', 'order created');
select results_eq(
  $$ select status::text, ticket_count, total_minor, payment_ref from public.orders where buyer_id = '00000000-0000-0000-0000-000000000b01' $$,
  $$ values ('submitted', 2, 300000, 'REF1001') $$, 'order totals and normalised payment ref');
select is((select count(*)::int from public.tickets where buyer_id = '00000000-0000-0000-0000-000000000b01' and status = 'pending'),
          2, 'two pending tickets');
select is((select jsonb_array_length(payload -> 'tickets') from public.notification_outbox where kind = 'order_received'),
          2, 'order_received email queued with both QR codes');
select is((select count(*)::int from public.audit_log where action = 'order.create'), 1, 'order creation is audited');

select is((pg_temp.buy('00000000-0000-0000-0000-000000000b01', 2, 'ref-1001', 'a1',
                       '00000000-0000-0000-0000-00000000aaaa') ->> 'replayed'), 'true', 'same idempotency key replays');
select is((select count(*)::int from public.orders), 1, 'replay did not create a second order');

-- create_order: validation (SD-14) and business rules ----------------------------
select throws_ok($$ select pg_temp.buy('00000000-0000-0000-0000-000000000b02', 1, 'a-b-1', 'b0') $$,
                 'P0001', 'VALIDATION', 'payment ref shorter than 4 chars after normalising -> VALIDATION (SD-14)');
select throws_ok($$ select public.create_order('00000000-0000-0000-0000-000000000b02', gen_random_uuid(), '[{"name":"X"}]',
                    'P', null, 'ref-2001', null, 'x', rpad('b0', 64, '0'), 'image/jpeg', 1) $$,
                 'P0001', 'VALIDATION', 'holder name check violation -> VALIDATION (SD-14)');
select throws_ok($$ select public.create_order('00000000-0000-0000-0000-000000000b02', gen_random_uuid(), '[{"phone":"1"}]',
                    'P', null, 'ref-2002', null, 'x', rpad('b9', 64, '0'), 'image/jpeg', 1) $$,
                 'P0001', 'VALIDATION', 'missing holder name -> VALIDATION');
select throws_ok($$ select public.create_order('00000000-0000-0000-0000-000000000b02', gen_random_uuid(), '{}',
                    'P', null, 'ref-2003', null, 'x', rpad('b8', 64, '0'), 'image/jpeg', 1) $$,
                 'P0001', 'VALIDATION', 'holders must be an array');
select throws_ok($$ select pg_temp.buy('00000000-0000-0000-0000-000000000b02', 1, 'REF 1001', 'b1') $$,
                 'P0001', 'DUPLICATE_PAYMENT_REF', 'same payment ref as a live order');
select throws_ok($$ select pg_temp.buy('00000000-0000-0000-0000-000000000b02', 1, 'ref-2004', 'a1') $$,
                 'P0001', 'DUPLICATE_RECEIPT', 'same receipt hash as a live order');
select throws_ok($$ select pg_temp.buy('00000000-0000-0000-0000-000000000b02', 5, 'ref-2005', 'b2') $$,
                 'P0001', 'TOO_MANY_TICKETS_IN_ORDER', 'above max_tickets_per_order');
select throws_ok($$ select pg_temp.buy('00000000-0000-0000-0000-000000000b03', 1, 'ref-3001', 'c1') $$,
                 'P0001', 'PROFILE_INCOMPLETE', 'no name/phone -> PROFILE_INCOMPLETE');
select throws_ok($$ select pg_temp.buy('00000000-0000-0000-0000-000000000b04', 1, 'ref-4001', 'd1') $$,
                 'P0001', 'ACCOUNT_SUSPENDED', 'suspended buyer -> ACCOUNT_SUSPENDED (SD-5)');

update public.event_config set sales_paused = true;
select throws_ok($$ select pg_temp.buy('00000000-0000-0000-0000-000000000b02', 1, 'ref-2006', 'b3') $$,
                 'P0001', 'SALES_CLOSED', 'paused sales -> SALES_CLOSED');
update public.event_config set sales_paused = false;

select pg_temp.buy('00000000-0000-0000-0000-000000000b01', 4, 'ref-1002', 'a2');           -- u1 now holds 6
select throws_ok($$ select pg_temp.buy('00000000-0000-0000-0000-000000000b01', 1, 'ref-1003', 'a3') $$,
                 'P0001', 'ACCOUNT_LIMIT', 'above max_tickets_per_account');
select pg_temp.buy('00000000-0000-0000-0000-000000000b02', 4, 'ref-2007', 'b4');           -- 10 of 10 seats taken
select is((public.get_public_event() ->> 'sold_out'), 'true', 'event shows sold out');
select throws_ok($$ select pg_temp.buy('00000000-0000-0000-0000-000000000b02', 1, 'ref-2008', 'b5') $$,
                 'P0001', 'CAPACITY_EXCEEDED', 'no seats left -> CAPACITY_EXCEEDED');

-- cancel_my_order --------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000000b02');
select throws_ok(format($$ select public.cancel_my_order(%L) $$,
                   (select id from public.orders where payment_ref = 'REF1001')),
                 'P0001', 'NOT_FOUND', 'cannot cancel another user''s order');
select public.cancel_my_order((select id from public.orders where payment_ref = 'REF2007'));
select is((select count(*)::int from public.tickets t join public.orders o on o.id = t.order_id
           where o.payment_ref = 'REF2007' and t.status = 'void'), 4, 'cancel voids the tickets');
select is((public.get_public_event() ->> 'sold_out'), 'false', 'cancelled seats are released');

-- resubmit_order ---------------------------------------------------------------
select throws_ok(format($$ select public.resubmit_order('00000000-0000-0000-0000-000000000b01', %L,
                    'P', null, 'ref-1010', null, 'x', rpad('a9', 64, '0'), 'image/jpeg', 1) $$,
                   (select id from public.orders where payment_ref = 'REF1001')),
                 'P0001', 'INVALID_TRANSITION', 'only rejected orders can be resubmitted');
update public.orders set status = 'rejected', reject_reason_code = 'payment_not_found',
                         hold_expires_at = now() + interval '1 day' where payment_ref = 'REF1001';
select is((public.resubmit_order('00000000-0000-0000-0000-000000000b01',
             (select id from public.orders where payment_ref = 'REF1001'),
             'P', null, 'ref-1010', null, 'x', rpad('a9', 64, '0'), 'image/jpeg', 1) ->> 'status'),
          'submitted', 'rejected order resubmitted');
select results_eq($$ select resubmit_count, payment_ref, reject_reason_code from public.orders where payment_ref = 'REF1010' $$,
                  $$ values (1, 'REF1010', null::text) $$, 'resubmit bumps the count and clears the rejection');

-- Ticket and info reads ----------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000000b01');
select is((select count(*)::int from public.my_order_tickets((select id from public.orders where payment_ref = 'REF1010'))
           where qr like 'ST1.%'), 2, 'owner gets tickets with QR payloads');
select is(public.get_whatsapp_group(), 'https://chat.whatsapp.com/AbC123', 'buyer with a live order gets the WhatsApp link');
select pg_temp.as_user('00000000-0000-0000-0000-000000000b02');
select is((select count(*)::int from public.my_order_tickets((select id from public.orders where payment_ref = 'REF1010'))),
          0, 'another user gets no tickets (IDOR)');
select pg_temp.as_user('00000000-0000-0000-0000-000000000b03');
select is(public.get_whatsapp_group(), null, 'user without an order gets no WhatsApp link');

-- Not callable from the API until 006 -------------------------------------------
select ok(not has_function_privilege('anon', 'public.create_order(uuid,uuid,jsonb,text,text,text,date,text,text,text,int)', 'execute')
      and not has_function_privilege('authenticated', 'public.create_order(uuid,uuid,jsonb,text,text,text,date,text,text,text,int)', 'execute'),
          'create_order is not executable by anon/authenticated');

select * from finish();
rollback;
