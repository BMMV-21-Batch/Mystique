-- A-13 / T11: every public function x every role.
-- Outcome per call: 'denied' (no EXECUTE grant), 'forbidden' (the function's own role/MFA/session
-- check refused), or 'allowed' (access passed; a business error from dummy arguments still counts).
-- Every call runs in a sub-transaction that is always rolled back, so calls cannot affect each other.
begin;
create extension if not exists pgtap with schema extensions;
select plan(28);

-- Start from empty tables whatever the seed loaded (rolled back at the end with everything else).
-- replica mode skips triggers, incl. the audit guards, for these deletes only.
set local session_replication_role = replica;
delete from public.scan_log; delete from public.notification_outbox; delete from public.tickets; delete from public.orders;
delete from public.audit_log; delete from public.event_config; delete from public.profiles; delete from auth.users;
delete from storage.objects where bucket_id = 'receipts';
set local session_replication_role = origin;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000001001', 'mu@example.com'),
  ('00000000-0000-0000-0000-0000000010a1', 'ma@example.com'),
  ('00000000-0000-0000-0000-0000000010d1', 'md@example.com');
update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-0000000010a1';
update public.profiles set role = 'dev'   where id = '00000000-0000-0000-0000-0000000010d1';

-- Roles, in column order: anon, user, admin (aal1), admin (aal2), dev (aal2), service_role
create function pg_temp.try(p_sql text, p_role text, p_claims jsonb) returns text language plpgsql as $$
declare v text;
begin
  begin
    perform set_config('request.jwt.claims', p_claims::text, true);
    execute format('set local role %I', p_role);
    execute p_sql;
    raise exception using errcode = 'XT001';                     -- always roll the call back
  exception when others then
    v := case when sqlstate = 'XT001' then 'allowed'
              when sqlstate = '42501' then 'denied'
              when sqlerrm in ('FORBIDDEN', 'UNAUTHENTICATED') then 'forbidden'
              else 'allowed' end;
  end;
  return v;
end $$;

create function pg_temp.matrix(p_sql text) returns text[] language sql as $$
  select array[
    pg_temp.try(p_sql, 'anon',          '{"role":"anon"}'),
    pg_temp.try(p_sql, 'authenticated', '{"role":"authenticated","sub":"00000000-0000-0000-0000-000000001001","aal":"aal2"}'),
    pg_temp.try(p_sql, 'authenticated', '{"role":"authenticated","sub":"00000000-0000-0000-0000-0000000010a1","aal":"aal1"}'),
    pg_temp.try(p_sql, 'authenticated', '{"role":"authenticated","sub":"00000000-0000-0000-0000-0000000010a1","aal":"aal2"}'),
    pg_temp.try(p_sql, 'authenticated', '{"role":"authenticated","sub":"00000000-0000-0000-0000-0000000010d1","aal":"aal2"}'),
    pg_temp.try(p_sql, 'service_role',  '{"role":"service_role"}')]
$$;

-- The matrix. "service" functions are called by Edge Functions / cron with an explicit actor.
create temp table m (fn text primary key, call text not null, expect text[] not null);
insert into m values
 -- public
 ('get_public_event()', 'select public.get_public_event()',
   '{allowed,allowed,allowed,allowed,allowed,allowed}'),
 -- signed-in user (any role; service_role has no session, so session-bound ones refuse it)
 ('get_payment_instructions()', 'select public.get_payment_instructions()',
   '{denied,allowed,allowed,allowed,allowed,allowed}'),
 ('get_whatsapp_group()', 'select public.get_whatsapp_group()',
   '{denied,allowed,allowed,allowed,allowed,allowed}'),
 ('update_my_profile(text,text,text,text,text)', 'select public.update_my_profile(''Matrix Person'', ''+94770009999'', null, null, ''en'')',
   '{denied,allowed,allowed,allowed,allowed,forbidden}'),
 ('set_my_locale(text)', 'select public.set_my_locale(''si'')',
   '{denied,allowed,allowed,allowed,allowed,forbidden}'),
 ('request_admin_access()', 'select public.request_admin_access()',
   '{denied,allowed,allowed,allowed,allowed,forbidden}'),
 ('cancel_my_order(uuid)', 'select public.cancel_my_order(gen_random_uuid())',
   '{denied,allowed,allowed,allowed,allowed,forbidden}'),
 ('my_order_tickets(uuid)', 'select * from public.my_order_tickets(gen_random_uuid())',
   '{denied,allowed,allowed,allowed,allowed,allowed}'),
 ('my_upload_quota()', 'select public.my_upload_quota()',
   '{denied,allowed,allowed,allowed,allowed,allowed}'),
 -- admin (aal2)
 ('approve_order(uuid,text)', 'select public.approve_order(gen_random_uuid())',
   '{denied,forbidden,forbidden,allowed,allowed,forbidden}'),
 ('reject_order(uuid,text,text,boolean)', 'select public.reject_order(gen_random_uuid(), ''other'')',
   '{denied,forbidden,forbidden,allowed,allowed,forbidden}'),
 ('check_in_ticket(text,text,text,timestamp with time zone,boolean)', 'select public.check_in_ticket(''x'', ''G'')',
   '{denied,forbidden,forbidden,allowed,allowed,forbidden}'),
 ('admin_undo_check_in(uuid,text)', 'select public.admin_undo_check_in(gen_random_uuid(), ''matrix test'')',
   '{denied,forbidden,forbidden,allowed,allowed,forbidden}'),
 ('scanner_manifest()', 'select * from public.scanner_manifest()',
   '{denied,forbidden,forbidden,allowed,allowed,forbidden}'),
 ('sync_offline_scans(jsonb)', 'select public.sync_offline_scans(''[]'')',
   '{denied,forbidden,forbidden,allowed,allowed,forbidden}'),
 ('mark_whatsapp_added(uuid,boolean)', 'select public.mark_whatsapp_added(gen_random_uuid(), true)',
   '{denied,forbidden,forbidden,allowed,allowed,forbidden}'),
 ('admin_set_status(uuid,account_status,text)', 'select public.admin_set_status(gen_random_uuid(), ''suspended'', ''matrix test'')',
   '{denied,forbidden,forbidden,allowed,allowed,forbidden}'),
 ('admin_analytics()', 'select public.admin_analytics()',
   '{denied,forbidden,forbidden,allowed,allowed,forbidden}'),
 -- dev (aal2)
 ('dev_set_admin(uuid,boolean)', 'select public.dev_set_admin(gen_random_uuid(), true)',
   '{denied,forbidden,forbidden,forbidden,allowed,forbidden}'),
 ('dev_update_event_config(jsonb)', 'select public.dev_update_event_config(''{}'')',
   '{denied,forbidden,forbidden,forbidden,allowed,forbidden}'),
 ('dev_health()', 'select public.dev_health()',
   '{denied,forbidden,forbidden,forbidden,allowed,forbidden}'),
 -- service_role only
 ('create_order(uuid,uuid,jsonb,text,text,text,date,text,text,text,integer)',
   'select public.create_order(gen_random_uuid(), gen_random_uuid(), ''[]'', ''p'', null, ''abcd'', null, ''x'', ''x'', ''x'', 1)',
   '{denied,denied,denied,denied,denied,allowed}'),
 ('resubmit_order(uuid,uuid,text,text,text,date,text,text,text,integer)',
   'select public.resubmit_order(gen_random_uuid(), gen_random_uuid(), ''p'', null, ''abcd'', null, ''x'', ''x'', ''x'', 1)',
   '{denied,denied,denied,denied,denied,allowed}'),
 ('expire_stale_orders()', 'select public.expire_stale_orders()',
   '{denied,denied,denied,denied,denied,allowed}'),
 ('claim_notifications(integer)', 'select * from public.claim_notifications(1)',
   '{denied,denied,denied,denied,denied,allowed}'),
 ('mark_notification(bigint,boolean,text)', 'select public.mark_notification(0, true)',
   '{denied,denied,denied,denied,denied,allowed}');

-- Completeness: a new function must be added to this matrix (and granted in its migration).
select set_eq(
  $$ select p.oid::regprocedure::text from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' $$,
  $$ select fn from m $$,
  'every public function is in the access matrix');

-- One assertion per function: [anon, user, admin aal1, admin aal2, dev, service_role]
select is(pg_temp.matrix(call), expect, fn) from m order by fn;

-- The matrix ran as other roles; make sure we are back to the test's own role.
select is(current_user::text, 'postgres', 'role restored after the matrix');

select * from finish();
rollback;
