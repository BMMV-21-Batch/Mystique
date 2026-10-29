-- A-14 / T13: every state-changing function writes its audit row, with the right actor, role,
-- entity, old -> new state, and the request id / client IP from the request headers.
-- Not audited by design: reads, set_my_locale (a preference), the outbox worker, and
-- sync_offline_scans (each scan it forwards is audited by check_in_ticket).
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

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000002001', 'au1@example.com'),
  ('00000000-0000-0000-0000-000000002002', 'au2@example.com'),
  ('00000000-0000-0000-0000-0000000020a1', 'aa1@example.com'),
  ('00000000-0000-0000-0000-0000000020d1', 'ad1@example.com');
update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-0000000020a1';
update public.profiles set role = 'dev'   where id = '00000000-0000-0000-0000-0000000020d1';

create function pg_temp.as_user(uid text, aal text default 'aal2') returns void language sql as $$
  select set_config('request.jwt.claims', case when uid is null then '' else json_build_object('sub', uid, 'aal', aal)::text end, true)
$$;
create function pg_temp.buy(ref text) returns uuid language sql as $$
  select (public.create_order('00000000-0000-0000-0000-000000002001', gen_random_uuid(), '[{"name":"Audit Holder"}]',
          'Payer', null, ref, current_date, 'x/' || ref || '.jpg', rpad(md5(ref), 64, '0'), 'image/jpeg', 1) ->> 'order_id')::uuid
$$;
create temp table k (name text primary key, id uuid);

-- Every call below carries the same request headers, as PostgREST would set them.
select set_config('request.headers', '{"x-request-id":"req-a14","x-forwarded-for":"198.51.100.4"}', true);

-- The flow ------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000020d1');
select public.dev_update_event_config(jsonb_build_object('name', 'Audit Party', 'starts_at', now() + interval '30 days',
  'capacity', 50, 'unit_price_minor', 1000, 'sales_open_at', now() - interval '1 day', 'sales_close_at', now() + interval '1 day'));
select pg_temp.as_user('00000000-0000-0000-0000-000000002001');
select public.update_my_profile('Audit User', '+94770002001', null, null, 'en');
select public.set_my_locale('si');                                                          -- not audited
select public.request_admin_access();
select pg_temp.as_user(null);                                                                -- Edge Function (service)
insert into k values ('o1', pg_temp.buy('AUD-1')), ('o2', pg_temp.buy('AUD-2'));
select pg_temp.as_user('00000000-0000-0000-0000-000000002001');
select public.cancel_my_order((select id from k where name = 'o2'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000020a1');
select public.reject_order((select id from k where name = 'o1'), 'receipt_unreadable');
select pg_temp.as_user(null);
select public.resubmit_order('00000000-0000-0000-0000-000000002001', (select id from k where name = 'o1'), 'Payer', null,
                             'AUD-1B', current_date, 'x/aud-1b.jpg', rpad(md5('AUD-1B'), 64, '0'), 'image/jpeg', 1);
select pg_temp.as_user('00000000-0000-0000-0000-0000000020a1');
select public.approve_order((select id from k where name = 'o1'));
insert into k select 't1', id from public.tickets where order_id = (select id from k where name = 'o1');
select public.check_in_ticket((select private.qr_payload(id, qr_version) from public.tickets where id = (select id from k where name = 't1')), 'G1');
select public.check_in_ticket('garbage', 'G1');                                             -- invalid scan: scan_log only
select public.admin_undo_check_in((select id from k where name = 't1'), 'scanned by mistake');
select public.sync_offline_scans('[]');                                                     -- nothing to forward
select count(*) from public.scanner_manifest();
select public.mark_whatsapp_added('00000000-0000-0000-0000-000000002001', true);
select public.admin_set_status('00000000-0000-0000-0000-000000002002', 'suspended', 'audit test');
select pg_temp.as_user('00000000-0000-0000-0000-0000000020d1');
select public.dev_set_admin('00000000-0000-0000-0000-000000002002', true);
select pg_temp.as_user(null);
insert into k values ('o3', pg_temp.buy('AUD-3'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000020a1');
select public.reject_order((select id from k where name = 'o3'), 'payment_not_found');
update public.orders set hold_expires_at = now() - interval '1 minute' where id = (select id from k where name = 'o3');
select pg_temp.as_user(null);                                                                -- cron
select public.expire_stale_orders();

-- The trail ---------------------------------------------------------------------------------
select results_eq(
  $$ select action, coalesce(actor_role, '-') from public.audit_log order by id $$,
  $$ values ('config.update', 'dev'),
            ('profile.update', 'user'), ('admin.request', 'user'),
            ('order.create', 'user'), ('order.create', 'user'), ('order.cancel', 'user'),
            ('order.reject', 'admin'), ('order.resubmit', 'user'), ('order.approve', 'admin'),
            ('ticket.check_in', 'admin'), ('ticket.undo_check_in', 'admin'), ('scanner.manifest_export', 'admin'),
            ('user.whatsapp_added', 'admin'), ('user.suspend', 'admin'), ('admin.grant', 'dev'),
            ('order.create', 'user'), ('order.reject', 'admin'), ('order.expire', '-') $$,
  'every state change leaves exactly the expected audit row, in order');

select is((select count(*)::int from public.audit_log where request_id = 'req-a14' and ip = '198.51.100.4'),
          (select count(*)::int from public.audit_log), 'every row carries the request id and client IP');
select is((select count(*)::int from public.audit_log where actor_id is null), 1, 'only the cron expiry has no actor');
select is((select count(*)::int from public.audit_log where action like 'order.%' and entity_type = 'order'
           and entity_id in (select id::text from k)), 9, 'all 9 order rows point at their order');

select results_eq(
  format($$ select action, old_data ->> 'status', new_data ->> 'status' from public.audit_log
            where entity_id = %L and action in ('order.reject', 'order.resubmit', 'order.approve') order by id $$,
         (select id from k where name = 'o1')),
  $$ values ('order.reject', 'submitted', 'rejected'), ('order.resubmit', 'rejected', 'submitted'),
            ('order.approve', 'submitted', 'approved') $$,
  'review rows record the old and new state');
select is((select actor_id from public.audit_log where action = 'order.resubmit'), '00000000-0000-0000-0000-000000002001'::uuid,
          'service calls are attributed to the buyer, not the Edge Function');
select is((select meta ->> 'reason' from public.audit_log where action = 'user.suspend'), 'audit test', 'suspension keeps its reason');
select is((select meta ->> 'reason' from public.audit_log where action = 'ticket.undo_check_in'), 'scanned by mistake',
          'undo keeps its reason');
select is((select new_data ->> 'gate' from public.audit_log where action = 'ticket.check_in'), 'G1', 'check-in records the gate');

select * from finish();
rollback;
