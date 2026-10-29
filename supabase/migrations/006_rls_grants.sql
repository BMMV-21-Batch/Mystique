-- 006: RLS policies, grants, default privileges (A-07, spec §6.6, N-2, SD-3)
--
-- Clients get SELECT through RLS and EXECUTE on named functions. Nothing else.
-- Reviewers: any new function without an explicit grant here (or in its own migration) is a bug.

-- Start from zero, then grant only what is needed.
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema private from public, anon, authenticated;

-- SD-3: objects created later (by migrations, which run as postgres) get no client access by default.
-- Supabase's grants to anon/authenticated are per-schema defaults; PUBLIC's EXECUTE on functions is a
-- built-in GLOBAL default that a per-schema command cannot remove, hence the last line.
alter default privileges for role postgres in schema public revoke all     on tables    from anon, authenticated;
alter default privileges for role postgres in schema public revoke all     on sequences from anon, authenticated;
alter default privileges for role postgres in schema public revoke execute on functions from anon, authenticated;
alter default privileges for role postgres                  revoke execute on functions from public;

grant usage on schema private to authenticated;       -- needed so RLS policies can call the two helpers
grant execute on function private.is_admin(), private.is_dev() to authenticated;

alter table public.profiles            enable row level security;
alter table public.orders              enable row level security;
alter table public.tickets             enable row level security;
alter table public.event_config        enable row level security;
alter table public.rejection_reasons   enable row level security;
alter table public.audit_log           enable row level security;
alter table public.scan_log            enable row level security;
alter table public.notification_outbox enable row level security;

grant select on public.profiles, public.orders, public.tickets, public.rejection_reasons,
                public.audit_log, public.scan_log, public.notification_outbox, public.event_config to authenticated;
grant select on public.admin_orders_v, public.admin_users_v, public.admin_door_list_v to authenticated;

-- (select …) wrappers make Postgres evaluate each check once per query, not once per row.
create policy profiles_select on public.profiles for select to authenticated
  using (id = (select auth.uid()) or (select private.is_admin()));
create policy orders_select   on public.orders   for select to authenticated
  using (buyer_id = (select auth.uid()) or (select private.is_admin()));
create policy tickets_select  on public.tickets  for select to authenticated
  using (buyer_id = (select auth.uid()) or (select private.is_admin()));
create policy reasons_select  on public.rejection_reasons for select to authenticated using (true);
create policy audit_select    on public.audit_log for select to authenticated using ((select private.is_dev()));
create policy scan_select     on public.scan_log  for select to authenticated using ((select private.is_admin()));
create policy outbox_select   on public.notification_outbox for select to authenticated using ((select private.is_dev()));
create policy config_select   on public.event_config for select to authenticated using ((select private.is_admin()));  -- users use get_public_event()

-- Function grants (explicit; everything else was revoked above)
grant execute on function public.get_public_event()                          to anon, authenticated;
grant execute on function public.get_payment_instructions(),
                           public.get_whatsapp_group(),
                           public.update_my_profile(text, text, text, text, text),
                           public.set_my_locale(text),
                           public.request_admin_access(),
                           public.cancel_my_order(uuid),
                           public.my_order_tickets(uuid),
                           public.approve_order(uuid, text),
                           public.reject_order(uuid, text, text, boolean),
                           public.check_in_ticket(text, text, text, timestamptz, boolean),
                           public.admin_undo_check_in(uuid, text),
                           public.scanner_manifest(),
                           public.sync_offline_scans(jsonb),
                           public.mark_whatsapp_added(uuid, boolean),
                           public.admin_set_status(uuid, public.account_status, text),
                           public.admin_analytics(),
                           public.dev_set_admin(uuid, boolean),
                           public.dev_update_event_config(jsonb),
                           public.dev_health()                               to authenticated;
-- service_role only (Edge Functions / cron)
grant execute on function public.create_order(uuid, uuid, jsonb, text, text, text, date, text, text, text, int),
                           public.resubmit_order(uuid, uuid, text, text, text, date, text, text, text, int),
                           public.expire_stale_orders(),
                           public.claim_notifications(int),
                           public.mark_notification(bigint, boolean, text)   to service_role;
