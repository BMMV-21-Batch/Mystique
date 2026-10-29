-- 008: scheduled jobs (A-09, spec §6.8, SD-15)
--
-- The send-notifications URL and its secret come from Vault, so the same migration works on
-- staging and prod (SD-15). Set them ONCE per environment (never commit the values):
--   select vault.create_secret('https://<ref>.supabase.co/functions/v1/send-notifications', 'notify_url');
--   select vault.create_secret('<same value as the CRON_SECRET Edge Function secret>', 'cron_secret');
-- Until both exist (e.g. locally), the outbox drain is a no-op instead of failing every minute.

create or replace function private.trigger_send_notifications() returns bigint
language plpgsql security definer set search_path = '' as $$
declare v_url text; v_secret text;
begin
  select decrypted_secret into v_url    from vault.decrypted_secrets where name = 'notify_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'cron_secret';
  if v_url is null or v_secret is null then return null; end if;
  if not exists (select 1 from public.notification_outbox where status in ('queued', 'failed') and next_attempt_at <= now())
    then return null; end if;                                      -- nothing due: skip the HTTP call
  return net.http_post(url := v_url, headers := jsonb_build_object('x-cron-secret', v_secret), body := '{}'::jsonb);
end $$;
revoke execute on function private.trigger_send_notifications() from public, anon, authenticated;

select cron.schedule('expire-stale-orders', '*/5 * * * *', $$ select public.expire_stale_orders() $$);

-- release rows stuck in 'sending' (worker crashed mid-batch)
select cron.schedule('unstick-notifications', '*/5 * * * *', $$
  update public.notification_outbox set status = 'failed'
  where status = 'sending' and claimed_at < now() - interval '5 minutes' $$);

-- drain the outbox every minute (safety net; submit/approve also trigger a best-effort immediate send)
select cron.schedule('send-notifications', '* * * * *', $$ select private.trigger_send_notifications() $$);
