-- Migrations 007-008: receipt upload rules (own folder, strict name, 10 per rolling 24 h - SD-2/SD-4),
-- no update/delete, read access, and the cron jobs with Vault-driven URL (SD-15).
begin;
create extension if not exists pgtap with schema extensions;
select plan(21);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000e01', 's1@example.com'),
  ('00000000-0000-0000-0000-000000000e02', 's2@example.com'),
  ('00000000-0000-0000-0000-000000000ea1', 'sa@example.com');
update public.profiles set role = 'admin' where id = '00000000-0000-0000-0000-000000000ea1';

create function pg_temp.as_user(uid text, aal text default 'aal1') returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'aal', aal, 'role', 'authenticated')::text, true)
$$;
create function pg_temp.upload(folder text, ext text default 'jpg') returns void language sql as $$
  insert into storage.objects (bucket_id, name, owner_id) values ('receipts', folder || '/' || gen_random_uuid() || '.' || ext, folder)
$$;
grant execute on function pg_temp.upload(text, text) to authenticated;

select is((select public::text || ' ' || file_size_limit from storage.buckets where id = 'receipts'), 'false 2097152',
          'receipts bucket is private with a 2 MB limit');

-- Upload rules ----------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000000e01');
set local role authenticated;
select lives_ok($$ select pg_temp.upload('00000000-0000-0000-0000-000000000e01') $$, 'user uploads into their own folder');
select throws_ok($$ select pg_temp.upload('00000000-0000-0000-0000-000000000e02') $$, '42501', null, 'cannot upload into another user''s folder');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('receipts', '00000000-0000-0000-0000-000000000e01/../x.jpg') $$,
                 '42501', null, 'path traversal name is refused (SD-4)');
select throws_ok($$ select pg_temp.upload('00000000-0000-0000-0000-000000000e01', 'exe') $$, '42501', null, 'unknown extension is refused');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('receipts', '00000000-0000-0000-0000-000000000e01/a/b.jpg') $$,
                 '42501', null, 'nested folders are refused');
select is((public.my_upload_quota() ->> 'remaining')::int, 9, 'quota shows 9 uploads left');
select lives_ok($$ select pg_temp.upload('00000000-0000-0000-0000-000000000e01') from generate_series(1, 9) $$, 'uploads 2-10 succeed');
select is((public.my_upload_quota() ->> 'remaining')::int, 0, 'quota is used up');
select throws_ok($$ select pg_temp.upload('00000000-0000-0000-0000-000000000e01') $$, '42501', null, 'the 11th upload in 24 h is denied (SD-2)');
select is((select count(*)::int from storage.objects where bucket_id = 'receipts'), 10, 'user sees their own 10 receipts');
do $$ begin delete from storage.objects where bucket_id = 'receipts'; exception when others then null; end $$;
select is((select count(*)::int from storage.objects where bucket_id = 'receipts'), 10, 'user cannot delete receipts');
do $$ begin update storage.objects set name = name || 'x' where bucket_id = 'receipts'; exception when others then null; end $$;
select is((select count(*)::int from storage.objects where bucket_id = 'receipts' and name like '%x'), 0, 'user cannot rename receipts');
reset role;

update storage.objects set created_at = now() - interval '25 hours'
 where name like '00000000-0000-0000-0000-000000000e01/%'
   and id in (select id from storage.objects where name like '00000000-0000-0000-0000-000000000e01/%' limit 3);
select pg_temp.as_user('00000000-0000-0000-0000-000000000e01');
set local role authenticated;
select lives_ok($$ select pg_temp.upload('00000000-0000-0000-0000-000000000e01') $$, 'uploads work again once older ones leave the 24 h window');
reset role;

-- Read access ------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000000e02');
set local role authenticated;
select is((select count(*)::int from storage.objects where bucket_id = 'receipts'), 0, 'another user sees none of them');
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-000000000ea1', 'aal2');
set local role authenticated;
select is((select count(*)::int from storage.objects where bucket_id = 'receipts'), 11, 'admin with MFA sees every receipt');
reset role;

update public.profiles set status = 'suspended' where id = '00000000-0000-0000-0000-000000000e02';
select pg_temp.as_user('00000000-0000-0000-0000-000000000e02');
set local role authenticated;
select throws_ok($$ select pg_temp.upload('00000000-0000-0000-0000-000000000e02') $$, '42501', null, 'suspended user cannot upload (SD-5)');
reset role;

-- Cron (SD-15) -------------------------------------------------------------------------
select is((select array_agg(jobname::text order by jobname) from cron.job),
          array['expire-stale-orders', 'send-notifications', 'unstick-notifications'], 'the three jobs are scheduled');
select ok((select command not like '%supabase.co%' from cron.job where jobname = 'send-notifications'),
          'no project URL is hard-coded in the job (SD-15)');
select is(private.trigger_send_notifications(), null, 'without Vault secrets the drain is a no-op');
select vault.create_secret('http://127.0.0.1:9/never', 'notify_url');
select vault.create_secret('test-secret', 'cron_secret');
insert into public.notification_outbox (dedupe_key, kind, to_email, payload) values ('t:1', 'order_received', 'x@example.com', '{}');
select isnt(private.trigger_send_notifications(), null, 'with secrets and due mail, the drain queues an HTTP call');

select * from finish();
rollback;
