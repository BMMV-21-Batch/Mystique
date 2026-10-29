-- Migration 006: A-16 security queries, SD-3 default privileges, and an RLS read matrix
-- (anon / user / other user / admin aal1 / admin aal2 / dev). The full T11 matrix is A-13.
begin;
create extension if not exists pgtap with schema extensions;
select plan(30);

-- A-16: grants and function hygiene ----------------------------------------------
select is((select array_agg(distinct routine_name::text) from information_schema.routine_privileges
           where routine_schema = 'public' and grantee in ('anon', 'PUBLIC')),
          array['get_public_event'], 'only get_public_event is executable by anon/PUBLIC');
select is((select count(*)::int from pg_class
           where relnamespace = 'public'::regnamespace and relkind = 'r' and not relrowsecurity),
          0, 'RLS is on for every public table');
select is((select count(*)::int from pg_proc
           where prosecdef and pronamespace in ('public'::regnamespace, 'private'::regnamespace)
             and not coalesce(proconfig @> array['search_path=""'], false)),
          0, 'every SECURITY DEFINER function pins search_path to empty');
select is((select count(*)::int from information_schema.role_table_grants
           where table_schema = 'public' and grantee = 'authenticated' and privilege_type <> 'SELECT'),
          0, 'authenticated cannot write any table directly');
select ok(not has_function_privilege('authenticated', 'public.create_order(uuid,uuid,jsonb,text,text,text,date,text,text,text,int)', 'execute'),
          'create_order is service_role only');
select ok(has_function_privilege('service_role', 'public.create_order(uuid,uuid,jsonb,text,text,text,date,text,text,text,int)', 'execute'),
          'service_role can create orders');
select ok(not has_function_privilege('authenticated', 'private.qr_mac(uuid,smallint)', 'execute'),
          'the QR MAC helper is not callable by clients');

-- SD-3: things created later are closed by default
create function public.zz_new_fn() returns int language sql as $$ select 1 $$;
create table public.zz_new_table (id int);
select ok(not has_function_privilege('anon', 'public.zz_new_fn()', 'execute')
      and not has_function_privilege('authenticated', 'public.zz_new_fn()', 'execute'),
          'a new function gets no client EXECUTE by default (SD-3)');
select ok(not has_table_privilege('anon', 'public.zz_new_table', 'select')
      and not has_table_privilege('authenticated', 'public.zz_new_table', 'select'),
          'a new table gets no client access by default');

-- Fixtures ---------------------------------------------------------------------
insert into public.event_config (name, starts_at, capacity, unit_price_minor, sales_open_at, sales_close_at)
values ('Party', now() + interval '30 days', 100, 1000, now() - interval '1 day', now() + interval '1 day');
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000d01', 'r1@example.com'),
  ('00000000-0000-0000-0000-000000000d02', 'r2@example.com'),
  ('00000000-0000-0000-0000-000000000da1', 'ra@example.com'),
  ('00000000-0000-0000-0000-000000000dd1', 'rd@example.com');
update public.profiles set full_name = 'Reader One', phone_e164 = '+94771000001' where id = '00000000-0000-0000-0000-000000000d01';
update public.profiles set full_name = 'Reader Two', phone_e164 = '+94771000002' where id = '00000000-0000-0000-0000-000000000d02';
update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-000000000da1';
update public.profiles set role = 'dev'   where id = '00000000-0000-0000-0000-000000000dd1';
select public.create_order(b, gen_random_uuid(), '[{"name":"Holder A"}]', 'Payer', null, 'REF' || right(b::text, 4),
                           current_date, b || '/x.jpg', rpad(md5(b::text), 64, '0'), 'image/jpeg', 10)
from unnest(array['00000000-0000-0000-0000-000000000d01', '00000000-0000-0000-0000-000000000d02']::uuid[]) b;
select private.audit('test.row', 'x', null, null, null);
insert into public.scan_log (result, scanned_at) values ('invalid', now());

-- Read matrix: rows visible per role ----------------------------------------------
create function pg_temp.as_user(uid text, aal text default 'aal2') returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'aal', aal, 'role', 'authenticated')::text, true)
$$;
create function pg_temp.counts() returns int[] language sql as $$
  select array[(select count(*) from public.profiles), (select count(*) from public.orders), (select count(*) from public.tickets),
               (select count(*) from public.audit_log), (select count(*) from public.scan_log),
               (select count(*) from public.notification_outbox), (select count(*) from public.event_config),
               (select count(*) from public.admin_orders_v)]::int[]
$$;
grant execute on function pg_temp.counts() to authenticated;

-- columns: profiles, orders, tickets, audit, scans, outbox, config, admin_orders_v
select pg_temp.as_user('00000000-0000-0000-0000-000000000d01');
set local role authenticated;
select is(pg_temp.counts(), array[1, 1, 1, 0, 0, 0, 0, 1], 'user sees only their own rows');
select is((select buyer_id from public.orders), '00000000-0000-0000-0000-000000000d01'::uuid, 'the visible order is their own');
select is((select count(*)::int from public.rejection_reasons), 5, 'users can read rejection reasons');
select throws_ok($$ insert into public.orders (buyer_id) values ('00000000-0000-0000-0000-000000000d01') $$,
                 '42501', null, 'user cannot insert orders directly');
select throws_ok($$ update public.profiles set role = 'dev' $$, '42501', null, 'user cannot promote themselves');
select throws_ok($$ select public.create_order('00000000-0000-0000-0000-000000000d01', gen_random_uuid(), '[]', 'p', null, 'abcd',
                    null, 'x', 'x', 'x', 1) $$, '42501', null, 'user cannot call create_order');
select lives_ok($$ select public.set_my_locale('si') $$, 'user can call their own functions');
reset role;

select pg_temp.as_user('00000000-0000-0000-0000-000000000da1', 'aal1');
set local role authenticated;
select is(pg_temp.counts(), array[1, 0, 0, 0, 0, 0, 0, 0], 'admin without MFA sees only their own profile');
select throws_ok($$ select public.admin_analytics() $$, 'P0001', 'FORBIDDEN', 'admin without MFA is refused');
reset role;

select pg_temp.as_user('00000000-0000-0000-0000-000000000da1');
set local role authenticated;
select is(pg_temp.counts(), array[4, 2, 2, 0, 1, 0, 1, 2], 'admin with MFA sees users, orders, tickets, scans, config');
select lives_ok($$ select public.admin_analytics() $$, 'admin with MFA can call admin functions');
reset role;

select pg_temp.as_user('00000000-0000-0000-0000-000000000dd1');
set local role authenticated;
select is(pg_temp.counts(), array[4, 2, 2, 3, 1, 2, 1, 2], 'dev also sees the audit log (2 orders + 1 test row) and outbox');
reset role;

update public.profiles set status = 'suspended' where id = '00000000-0000-0000-0000-000000000da1';
select pg_temp.as_user('00000000-0000-0000-0000-000000000da1');
set local role authenticated;
select is(pg_temp.counts(), array[1, 0, 0, 0, 0, 0, 0, 0], 'suspended admin sees only their own profile (SD-5)');
reset role;

-- anon -----------------------------------------------------------------------------
select set_config('request.jwt.claims', '{"role":"anon"}', true);
set local role anon;
select throws_ok($$ select count(*) from public.profiles $$,  '42501', null, 'anon cannot read profiles');
select throws_ok($$ select count(*) from public.orders $$,    '42501', null, 'anon cannot read orders');
select throws_ok($$ select count(*) from public.event_config $$, '42501', null, 'anon cannot read config directly');
select throws_ok($$ select count(*) from public.admin_orders_v $$, '42501', null, 'anon cannot read admin views');
select throws_ok($$ select public.get_payment_instructions() $$, '42501', null, 'anon cannot read bank details');
select is((public.get_public_event() ->> 'name'), 'Party', 'anon can read public event info');
select throws_ok($$ select public.approve_order(gen_random_uuid()) $$, '42501', null, 'anon cannot call admin functions');
select throws_ok($$ select private.is_admin() $$, '42501', null, 'anon cannot use the private schema');
reset role;

select * from finish();
rollback;
