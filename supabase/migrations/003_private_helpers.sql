-- 003: secrets, role checks, QR MAC, audit writer + guards, new-user trigger, mail enqueue
-- (A-04, spec §6.3, SD-6)

-- Server-side secret for QR MACs, one per environment. Generated inside the database on the
-- first run, so the value never exists in the repo, CI or a developer's machine.
-- Changing it invalidates every issued QR code.
create table private.secrets (name text primary key, value text not null);
revoke all on private.secrets from public, anon, authenticated;
insert into private.secrets (name, value)
values ('qr_hmac', encode(extensions.gen_random_bytes(32), 'hex'))
on conflict (name) do nothing;

-- Role checks. Admin and dev both REQUIRE aal2 (MFA).
create or replace function private.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
     and exists (select 1 from public.profiles p
                 where p.id = auth.uid() and p.role in ('admin', 'dev') and p.status = 'active')
$$;
create or replace function private.is_dev() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
     and exists (select 1 from public.profiles p
                 where p.id = auth.uid() and p.role = 'dev' and p.status = 'active')
$$;

-- QR MAC: 22 base64url chars (132 bits) of HMAC-SHA256(ticket id + version)
create or replace function private.qr_mac(p_ticket uuid, p_ver smallint) returns text
language sql stable security definer set search_path = '' as $$
  select translate(substr(encode(
           extensions.hmac('ticket:' || p_ticket::text || ':' || p_ver::text,
                           (select value from private.secrets where name = 'qr_hmac'),
                           'sha256'), 'base64'), 1, 22), '+/', '-_')
$$;

create or replace function private.qr_payload(p_ticket uuid, p_ver smallint) returns text
language sql stable security definer set search_path = '' as $$
  select 'ST1.' || p_ticket::text || '.' || private.qr_mac(p_ticket, p_ver)
$$;

-- Append-only audit writer. request_id / ip come from PostgREST request headers.
create or replace function private.audit(
  p_action text, p_entity text, p_entity_id text,
  p_old jsonb, p_new jsonb, p_meta jsonb default '{}'::jsonb,
  p_actor uuid default auth.uid()) returns void
language plpgsql security definer set search_path = '' as $$
declare h jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
begin
  insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, old_data, new_data, meta, ip, request_id)
  values (p_actor, (select role::text from public.profiles where id = p_actor), p_action, p_entity, p_entity_id,
          p_old, p_new, p_meta, nullif(split_part(coalesce(h ->> 'x-forwarded-for', ''), ',', 1), ''), h ->> 'x-request-id');
end $$;

-- Guards: UPDATE and DELETE per row, TRUNCATE per statement (SD-6).
create or replace function private.audit_immutable() returns trigger language plpgsql as $$
begin raise exception 'audit_log is append-only'; end $$;
create trigger audit_no_update before update or delete on public.audit_log
  for each row execute function private.audit_immutable();
create trigger audit_no_truncate before truncate on public.audit_log
  for each statement execute function private.audit_immutable();

-- New auth user -> bare profile (details are collected at first purchase)
create or replace function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, email, locale)
  values (new.id, lower(new.email),
          case when new.raw_user_meta_data ->> 'locale' = 'si' then 'si' else 'en' end);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function private.handle_new_user();

-- Builds the email payload INCLUDING qr payloads, and enqueues it (idempotent).
create or replace function private.enqueue_order_mail(p_order uuid, p_kind text) returns void
language plpgsql security definer set search_path = '' as $$
declare o public.orders; p public.profiles; cfg public.event_config; r public.rejection_reasons; v jsonb;
begin
  select * into o   from public.orders where id = p_order;
  select * into p   from public.profiles where id = o.buyer_id;
  select * into cfg from public.event_config where id = true;
  select * into r   from public.rejection_reasons where code = o.reject_reason_code;
  v := jsonb_build_object(
    'order_no', o.order_no, 'status', o.status, 'total_minor', o.total_minor, 'currency', o.currency,
    'buyer_name', p.full_name,
    'event', jsonb_build_object('name', cfg.name, 'venue', cfg.venue, 'starts_at', cfg.starts_at),
    'whatsapp_group_url', cfg.whatsapp_group_url,
    'reject', case when o.status = 'rejected' then jsonb_build_object(
                'code', o.reject_reason_code, 'label_en', r.label_en, 'label_si', r.label_si,
                'note', o.reject_reason_text, 'hold_expires_at', o.hold_expires_at) end,
    'tickets', (select coalesce(jsonb_agg(jsonb_build_object(
                  'seq', t.seq, 'holder_name', t.holder_name, 'short_code', t.short_code,
                  'status', t.status, 'qr', private.qr_payload(t.id, t.qr_version)) order by t.seq), '[]'::jsonb)
                from public.tickets t where t.order_id = o.id and t.status <> 'void'));
  insert into public.notification_outbox (dedupe_key, kind, user_id, to_email, locale, payload)
  values (format('%s:%s:%s', p_kind, o.id, o.resubmit_count), p_kind, p.id, p.email, p.locale, v)
  on conflict (dedupe_key) do nothing;
end $$;

-- private.* is not callable from the API until 006 grants the two role checks.
revoke execute on all functions in schema private from public, anon, authenticated;
