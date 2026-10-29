-- Migrations 001-003: lock-down, new-user trigger, role checks (aal2), QR MAC, audit guards (T12 incl. SD-6).
begin;
create extension if not exists pgtap with schema extensions;
select plan(24);

-- Start from empty tables whatever the seed loaded (rolled back at the end with everything else).
-- replica mode skips triggers, incl. the audit guards, for these deletes only.
set local session_replication_role = replica;
delete from public.scan_log; delete from public.notification_outbox; delete from public.tickets; delete from public.orders;
delete from public.audit_log; delete from public.event_config; delete from public.profiles; delete from auth.users;
delete from storage.objects where bucket_id = 'receipts';
set local session_replication_role = origin;

-- Lock-down until 006 -------------------------------------------------------
select is((select count(*)::int from pg_class
           where relnamespace = 'public'::regnamespace and relkind = 'r' and not relrowsecurity),
          0, 'every public table has RLS enabled');
select is((select count(*)::int from information_schema.role_table_grants
           where table_schema = 'public' and (grantee = 'anon' or (grantee = 'authenticated' and privilege_type <> 'SELECT'))),
          0, 'anon has no table grants; authenticated has SELECT only');
select ok(not has_schema_privilege('anon', 'private', 'usage'), 'anon cannot use schema private');
select ok(not has_table_privilege('authenticated', 'private.secrets', 'select'), 'authenticated cannot read private.secrets');

-- Codes ---------------------------------------------------------------------
select matches(private.gen_code('U', 6), '^U-[A-HJKMNP-Z2-9]{6}$', 'gen_code uses the unambiguous alphabet');

-- New-user trigger ------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'User.One@Example.com', '{"locale":"si"}'),
  ('00000000-0000-0000-0000-0000000000a2', 'admin@example.com',    '{}'),
  ('00000000-0000-0000-0000-0000000000a3', 'dev@example.com',      '{}');
select is((select email from public.profiles where id = '00000000-0000-0000-0000-0000000000a1'),
          'user.one@example.com', 'profile email is lower-cased');
select is((select locale from public.profiles where id = '00000000-0000-0000-0000-0000000000a1'),
          'si', 'locale comes from signup metadata');
select is((select locale from public.profiles where id = '00000000-0000-0000-0000-0000000000a2'),
          'en', 'locale defaults to en');
select matches((select public_code from public.profiles where id = '00000000-0000-0000-0000-0000000000a1'),
          '^U-[A-HJKMNP-Z2-9]{6}$', 'profile gets a public_code');
select is((select role::text from public.profiles where id = '00000000-0000-0000-0000-0000000000a1'),
          'user', 'new profiles are plain users');

update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-0000000000a2';
update public.profiles set role = 'dev'   where id = '00000000-0000-0000-0000-0000000000a3';

-- Role checks: admin and dev need aal2 and an active account ------------------
create function pg_temp.as_user(uid text, aal text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'aal', aal)::text, true)
$$;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2', 'aal1');
select ok(not private.is_admin(), 'admin at aal1 is not admin');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2', 'aal2');
select ok(private.is_admin(), 'admin at aal2 is admin');
select ok(not private.is_dev(), 'admin at aal2 is not dev');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a3', 'aal2');
select ok(private.is_admin() and private.is_dev(), 'dev at aal2 is admin and dev');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1', 'aal2');
select ok(not private.is_admin(), 'plain user at aal2 is not admin');

update public.profiles set status = 'suspended' where id = '00000000-0000-0000-0000-0000000000a2';
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2', 'aal2');
select ok(not private.is_admin(), 'suspended admin at aal2 is not admin (SD-5)');

-- QR MAC ----------------------------------------------------------------------
select matches(private.qr_payload('11111111-1111-1111-1111-111111111111', 1::smallint),
          '^ST1\.11111111-1111-1111-1111-111111111111\.[A-Za-z0-9_-]{22}$', 'QR payload format');
select is(private.qr_mac('11111111-1111-1111-1111-111111111111', 1::smallint),
          private.qr_mac('11111111-1111-1111-1111-111111111111', 1::smallint), 'QR MAC is deterministic');
select isnt(private.qr_mac('11111111-1111-1111-1111-111111111111', 1::smallint),
            private.qr_mac('11111111-1111-1111-1111-111111111111', 2::smallint), 'bumping qr_version changes the MAC');

-- Audit writer + guards (T12, SD-6) -------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a3', 'aal2');
select set_config('request.headers', '{"x-forwarded-for":"203.0.113.7, 10.0.0.1","x-request-id":"req-123"}', true);
select private.audit('test.action', 'order', 'X', null, '{"a":1}');
select results_eq(
  $$ select actor_id::text, actor_role, ip, request_id from public.audit_log where action = 'test.action' $$,
  $$ values ('00000000-0000-0000-0000-0000000000a3', 'dev', '203.0.113.7', 'req-123') $$,
  'audit row records actor, role, first forwarded IP and request id');

select throws_ok($$ update public.audit_log set action = 'x' $$, 'P0001', 'audit_log is append-only', 'audit UPDATE is blocked');
select throws_ok($$ delete from public.audit_log $$,         'P0001', 'audit_log is append-only', 'audit DELETE is blocked');
select throws_ok($$ truncate public.audit_log $$,            'P0001', 'audit_log is append-only', 'audit TRUNCATE is blocked (SD-6)');
select is((select count(*)::int from public.audit_log where action = 'test.action'), 1, 'audit row survived');

select * from finish();
rollback;
