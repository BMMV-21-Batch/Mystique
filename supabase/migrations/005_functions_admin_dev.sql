-- 005: review, expiry, check-in, admin/dev tools, notifications worker, views, analytics
-- (A-06, spec §6.5, SD-1, SD-5, SD-10, SD-12, SD-13, SD-17, SD-19)
--
-- Admin/dev checks go through private.is_admin()/is_dev(), which require aal2 AND an active
-- account, so a suspended admin fails every call here on their next request (SD-5).

---------------------------------------------------------------- mail payload (replaces 003)
-- The reject block is now included whenever a reason exists, so a reject-and-release
-- (status 'expired', SD-1) still tells the buyer why. 'released' says whether seats were kept.
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
    'reject', case when o.reject_reason_code is not null then jsonb_build_object(
                'code', o.reject_reason_code, 'label_en', r.label_en, 'label_si', r.label_si,
                'note', o.reject_reason_text, 'hold_expires_at', o.hold_expires_at,
                'released', o.status = 'expired') end,
    'tickets', (select coalesce(jsonb_agg(jsonb_build_object(
                  'seq', t.seq, 'holder_name', t.holder_name, 'short_code', t.short_code,
                  'status', t.status, 'qr', private.qr_payload(t.id, t.qr_version)) order by t.seq), '[]'::jsonb)
                from public.tickets t where t.order_id = o.id and t.status <> 'void'));
  insert into public.notification_outbox (dedupe_key, kind, user_id, to_email, locale, payload)
  values (format('%s:%s:%s', p_kind, o.id, o.resubmit_count), p_kind, p.id, p.email, p.locale, v)
  on conflict (dedupe_key) do nothing;
end $$;

---------------------------------------------------------------- review
create or replace function public.approve_order(p_order_id uuid, p_note text default null)
returns public.orders language plpgsql security definer set search_path = '' as $$
declare v_old public.orders; v_new public.orders;
begin
  if not private.is_admin() then raise exception 'FORBIDDEN'; end if;
  set local lock_timeout = '3s';
  select * into v_old from public.orders where id = p_order_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_old.buyer_id = auth.uid() then raise exception 'SELF_REVIEW_FORBIDDEN'; end if;   -- four-eyes
  if v_old.status <> 'submitted' then raise exception 'INVALID_TRANSITION'; end if;
  update public.orders set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(),
         review_note = nullif(btrim(p_note), ''),          -- a note TO THE BUYER (SD-8)
         hold_expires_at = null, reject_reason_code = null, reject_reason_text = null
  where id = p_order_id returning * into v_new;
  update public.tickets set status = 'valid' where order_id = p_order_id and status = 'pending';
  perform private.audit('order.approve', 'order', p_order_id::text, to_jsonb(v_old), to_jsonb(v_new));
  perform private.enqueue_order_mail(p_order_id, 'order_approved');
  return v_new;
end $$;

-- p_release (SD-1): for fraud / payment-not-found, end the order now ('expired', tickets void)
-- instead of holding the seats for rejected_hold_minutes.
create or replace function public.reject_order(p_order_id uuid, p_reason_code text, p_reason_text text default null,
                                               p_release boolean default false)
returns public.orders language plpgsql security definer set search_path = '' as $$
declare cfg public.event_config; v_old public.orders; v_new public.orders;
begin
  if not private.is_admin() then raise exception 'FORBIDDEN'; end if;
  set local lock_timeout = '3s';
  select * into cfg from public.event_config where id = true;
  select * into v_old from public.orders where id = p_order_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_old.buyer_id = auth.uid() then raise exception 'SELF_REVIEW_FORBIDDEN'; end if;
  if v_old.status <> 'submitted' then raise exception 'INVALID_TRANSITION'; end if;
  if not exists (select 1 from public.rejection_reasons where code = p_reason_code and active) then raise exception 'VALIDATION'; end if;
  if p_reason_code = 'other' and char_length(coalesce(btrim(p_reason_text), '')) < 3 then raise exception 'REASON_TEXT_REQUIRED'; end if;
  update public.orders set
         status = case when coalesce(p_release, false) then 'expired'::public.order_status else 'rejected'::public.order_status end,
         reviewed_by = auth.uid(), reviewed_at = now(),
         reject_reason_code = p_reason_code, reject_reason_text = nullif(btrim(p_reason_text), ''),
         hold_expires_at = case when coalesce(p_release, false) then null
                                else now() + make_interval(mins => cfg.rejected_hold_minutes) end
  where id = p_order_id returning * into v_new;
  if coalesce(p_release, false) then
    update public.tickets set status = 'void', void_reason = 'order_rejected_released'
    where order_id = p_order_id and status = 'pending';
  end if;                                                           -- otherwise tickets stay 'pending' = seats held
  perform private.audit('order.reject', 'order', p_order_id::text, to_jsonb(v_old), to_jsonb(v_new),
                        jsonb_build_object('release', coalesce(p_release, false)));
  perform private.enqueue_order_mail(p_order_id, 'order_rejected');
  return v_new;
end $$;

---------------------------------------------------------------- expiry (cron)
create or replace function public.expire_stale_orders() returns int
language plpgsql security definer set search_path = '' as $$
declare r record; n int := 0;
begin
  for r in select id from public.orders where status = 'rejected' and hold_expires_at < now() order by id for update skip locked loop
    update public.orders set status = 'expired' where id = r.id;
    update public.tickets set status = 'void', void_reason = 'order_expired' where order_id = r.id and status = 'pending';
    perform private.audit('order.expire', 'order', r.id::text, null, null, '{}'::jsonb, null);
    perform private.enqueue_order_mail(r.id, 'order_expired');
    n := n + 1;
  end loop;
  return n;
end $$;

---------------------------------------------------------------- check-in (the atomic core, §11)
create or replace function public.check_in_ticket(
  p_payload text, p_gate text, p_device text default null,
  p_scanned_at timestamptz default null, p_offline boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_mac text; t public.tickets; v_when timestamptz; v_res public.scan_result;
begin
  if not private.is_admin() then raise exception 'FORBIDDEN'; end if;
  -- trust the client clock only for offline syncs, and only within sane bounds
  v_when := case when p_offline and p_scanned_at between now() - interval '24 hours' and now() + interval '1 minute'
                 then p_scanned_at else now() end;

  -- Strict UUID shape (SD-13): anything else is 'invalid', never a cast exception.
  if p_payload is null
     or p_payload !~ '^ST1\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.[A-Za-z0-9_-]{22}$' then
    insert into public.scan_log (result, scanned_by, gate, device_id, offline, scanned_at)
    values ('invalid', auth.uid(), p_gate, p_device, p_offline, v_when);
    return jsonb_build_object('result', 'invalid');
  end if;
  v_id  := split_part(p_payload, '.', 2)::uuid;
  v_mac := split_part(p_payload, '.', 3);
  select * into t from public.tickets where id = v_id;
  if not found or v_mac <> private.qr_mac(t.id, t.qr_version) then
    insert into public.scan_log (result, scanned_by, gate, device_id, offline, scanned_at)
    values ('invalid', auth.uid(), p_gate, p_device, p_offline, v_when);
    return jsonb_build_object('result', 'invalid');
  end if;

  -- THE atomic step: exactly one concurrent caller can match this WHERE clause.
  update public.tickets set status = 'used', checked_in_at = v_when, checked_in_by = auth.uid(), checked_in_gate = p_gate
  where id = v_id and status = 'valid' and checked_in_at is null
  returning * into t;

  if found then
    v_res := 'ok';
  else
    select * into t from public.tickets where id = v_id;        -- re-read the winner's state
    v_res := case t.status when 'pending' then 'waiting_approval' when 'used' then 'already_used' else 'void' end;
  end if;

  insert into public.scan_log (ticket_id, result, scanned_by, gate, device_id, offline, scanned_at)
  values (t.id, v_res, auth.uid(), p_gate, p_device, p_offline, v_when);
  if v_res = 'ok' then
    perform private.audit('ticket.check_in', 'ticket', t.id::text, null, jsonb_build_object('gate', p_gate, 'offline', p_offline));
  end if;

  return jsonb_build_object(
    'result', v_res, 'ticket_id', t.id, 'short_code', t.short_code, 'holder_name', t.holder_name, 'seq', t.seq,
    'order_no', (select order_no from public.orders where id = t.order_id),
    'checked_in_at', t.checked_in_at, 'checked_in_gate', t.checked_in_gate);
end $$;

create or replace function public.admin_undo_check_in(p_ticket_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare t public.tickets;
begin
  if not private.is_admin() then raise exception 'FORBIDDEN'; end if;
  if char_length(coalesce(btrim(p_reason), '')) < 3 then raise exception 'REASON_TEXT_REQUIRED'; end if;
  update public.tickets set status = 'valid', checked_in_at = null, checked_in_by = null, checked_in_gate = null
  where id = p_ticket_id and status = 'used' returning * into t;
  if not found then raise exception 'INVALID_TRANSITION'; end if;
  perform private.audit('ticket.undo_check_in', 'ticket', p_ticket_id::text, null, null, jsonb_build_object('reason', p_reason));
end $$;

-- Offline support (P1): everything the scanner needs, with NO secret on the device.
-- VOLATILE, not STABLE: it writes an audit row (SD-12).
create or replace function public.scanner_manifest() returns table (
  ticket_id uuid, payload_sha256 text, short_code text, holder_name text, status public.ticket_status, order_no text)
language plpgsql volatile security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'FORBIDDEN'; end if;
  perform private.audit('scanner.manifest_export', 'ticket', null, null, null);
  return query
    select t.id, encode(extensions.digest(private.qr_payload(t.id, t.qr_version), 'sha256'), 'hex'),
           t.short_code, t.holder_name, t.status, o.order_no
    from public.tickets t join public.orders o on o.id = t.order_id
    where t.status <> 'void';
end $$;

-- Offline sync (P1): [{"payload","gate","device","scanned_at"}, …] -> per-scan result, in order.
-- A malformed scanned_at counts as "unknown" (server time is used), not a failed batch.
create or replace function public.sync_offline_scans(p_scans jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s jsonb; v_at timestamptz; out jsonb := '[]'::jsonb;
begin
  if not private.is_admin() then raise exception 'FORBIDDEN'; end if;
  if coalesce(jsonb_typeof(p_scans), '') <> 'array' or jsonb_array_length(p_scans) > 1000 then raise exception 'VALIDATION'; end if;
  for s in select * from jsonb_array_elements(p_scans) loop
    begin
      v_at := (s ->> 'scanned_at')::timestamptz;
    exception when data_exception then
      v_at := null;
    end;
    out := out || jsonb_build_array(public.check_in_ticket(
      s ->> 'payload', s ->> 'gate', s ->> 'device', v_at, true));
  end loop;
  return out;
end $$;

---------------------------------------------------------------- WhatsApp (A-6)
create or replace function public.mark_whatsapp_added(p_user_id uuid, p_added boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'FORBIDDEN'; end if;
  update public.profiles set whatsapp_added_at = case when p_added then now() end,
         whatsapp_added_by = case when p_added then auth.uid() end where id = p_user_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  perform private.audit('user.whatsapp_added', 'profile', p_user_id::text, null, jsonb_build_object('added', p_added));
end $$;

---------------------------------------------------------------- account suspension (SD-5)
-- Admins suspend/reactivate users; only a dev suspends/reactivates admins; nobody touches
-- themselves or a dev. Takes effect on the target's next request (every write and every
-- is_admin()/is_dev() check requires status = 'active'); no session revoke needed.
create or replace function public.admin_set_status(p_user_id uuid, p_status public.account_status, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_old public.profiles;
begin
  if not private.is_admin() then raise exception 'FORBIDDEN'; end if;
  if p_status is null then raise exception 'VALIDATION'; end if;
  if char_length(coalesce(btrim(p_reason), '')) < 3 then raise exception 'REASON_TEXT_REQUIRED'; end if;
  if p_user_id = auth.uid() then raise exception 'FORBIDDEN'; end if;
  select * into v_old from public.profiles where id = p_user_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_old.role = 'dev' then raise exception 'FORBIDDEN'; end if;
  if v_old.role = 'admin' and not private.is_dev() then raise exception 'FORBIDDEN'; end if;
  if v_old.status = p_status then return; end if;
  update public.profiles set status = p_status where id = p_user_id;
  perform private.audit(case when p_status = 'suspended' then 'user.suspend' else 'user.reactivate' end,
                        'profile', p_user_id::text,
                        jsonb_build_object('status', v_old.status), jsonb_build_object('status', p_status),
                        jsonb_build_object('reason', btrim(p_reason)));
end $$;

---------------------------------------------------------------- dev: admins & config
create or replace function public.dev_set_admin(p_user_id uuid, p_make_admin boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare v_old public.profiles;
begin
  if not private.is_dev() then raise exception 'FORBIDDEN'; end if;
  if p_user_id = auth.uid() then raise exception 'FORBIDDEN'; end if;
  select * into v_old from public.profiles where id = p_user_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_old.role = 'dev' then raise exception 'FORBIDDEN'; end if;
  if p_make_admin then
    update public.profiles set role = 'admin', admin_approved_by = auth.uid(), admin_approved_at = now(),
           staff_code = coalesce(staff_code, 'A' || lpad(nextval('private.staff_seq')::text, 3, '0'))
    where id = p_user_id;
  else
    update public.profiles set role = 'user' where id = p_user_id;           -- staff_code kept for audit continuity
  end if;
  perform private.audit(case when p_make_admin then 'admin.grant' else 'admin.revoke' end,
                        'profile', p_user_id::text, to_jsonb(v_old), null);
end $$;

-- Partial update: a key that is absent keeps its value. An explicit JSON null clears
-- whatsapp_group_url (SD-19). Creates the singleton row if none exists yet (first setup).
create or replace function public.dev_update_event_config(p jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare v_old public.event_config; v_new public.event_config;
begin
  if not private.is_dev() then raise exception 'FORBIDDEN'; end if;
  if coalesce(jsonb_typeof(p), '') <> 'object' then raise exception 'VALIDATION'; end if;
  select * into v_old from public.event_config where id = true for update;
  begin
    if found then
      update public.event_config set
        name = coalesce(p ->> 'name', name),
        venue = case when p ? 'venue' then p ->> 'venue' else venue end,
        starts_at = coalesce((p ->> 'starts_at')::timestamptz, starts_at),
        capacity = coalesce((p ->> 'capacity')::int, capacity),
        unit_price_minor = coalesce((p ->> 'unit_price_minor')::int, unit_price_minor),
        sales_open_at = coalesce((p ->> 'sales_open_at')::timestamptz, sales_open_at),
        sales_close_at = coalesce((p ->> 'sales_close_at')::timestamptz, sales_close_at),
        sales_paused = coalesce((p ->> 'sales_paused')::boolean, sales_paused),
        max_tickets_per_order = coalesce((p ->> 'max_tickets_per_order')::int, max_tickets_per_order),
        max_tickets_per_account = coalesce((p ->> 'max_tickets_per_account')::int, max_tickets_per_account),
        rejected_hold_minutes = coalesce((p ->> 'rejected_hold_minutes')::int, rejected_hold_minutes),
        max_resubmits = coalesce((p ->> 'max_resubmits')::int, max_resubmits),
        whatsapp_group_url = case when p ? 'whatsapp_group_url' then p ->> 'whatsapp_group_url' else whatsapp_group_url end,
        bank_details = coalesce(p -> 'bank_details', bank_details),
        updated_by = auth.uid(), updated_at = now()
      where id = true returning * into v_new;
    else
      insert into public.event_config (name, venue, starts_at, capacity, unit_price_minor, sales_open_at, sales_close_at,
                                       sales_paused, max_tickets_per_order, max_tickets_per_account,
                                       rejected_hold_minutes, max_resubmits, whatsapp_group_url, bank_details, updated_by)
      values (p ->> 'name', p ->> 'venue', (p ->> 'starts_at')::timestamptz, (p ->> 'capacity')::int,
              (p ->> 'unit_price_minor')::int, (p ->> 'sales_open_at')::timestamptz, (p ->> 'sales_close_at')::timestamptz,
              coalesce((p ->> 'sales_paused')::boolean, false), coalesce((p ->> 'max_tickets_per_order')::int, 10),
              coalesce((p ->> 'max_tickets_per_account')::int, 20), coalesce((p ->> 'rejected_hold_minutes')::int, 1440),
              coalesce((p ->> 'max_resubmits')::int, 3), p ->> 'whatsapp_group_url', coalesce(p -> 'bank_details', '{}'::jsonb),
              auth.uid())
      returning * into v_new;
    end if;
  exception when data_exception or check_violation or not_null_violation then
    raise exception 'VALIDATION';
  end;
  if v_new.sales_close_at <= v_new.sales_open_at or v_new.max_tickets_per_account < v_new.max_tickets_per_order
     or v_new.rejected_hold_minutes < 0 or v_new.max_resubmits < 0
     or jsonb_typeof(v_new.bank_details) <> 'object' then
    raise exception 'VALIDATION';
  end if;
  perform private.audit('config.update', 'event_config', 'singleton', to_jsonb(v_old), p);
end $$;

---------------------------------------------------------------- notification worker (service_role)
create or replace function public.claim_notifications(p_limit int default 20)
returns setof public.notification_outbox language sql security definer set search_path = '' as $$
  update public.notification_outbox n set status = 'sending', attempts = n.attempts + 1, claimed_at = now()
  where n.id in (select id from public.notification_outbox
                 where status in ('queued', 'failed') and next_attempt_at <= now()
                 order by id limit p_limit for update skip locked)
  returning n.*;
$$;

create or replace function public.mark_notification(p_id bigint, p_ok boolean, p_error text default null) returns void
language sql security definer set search_path = '' as $$
  update public.notification_outbox set
    status = case when p_ok then 'sent'::public.notif_status
                  when attempts >= 6 then 'dead'::public.notif_status else 'failed'::public.notif_status end,
    sent_at = case when p_ok then now() end,
    last_error = p_error,
    next_attempt_at = now() + make_interval(mins => attempts * attempts)
  where id = p_id;
$$;

---------------------------------------------------------------- views for the admin UI (PostgREST filter/sort/paginate)
create or replace view public.admin_orders_v with (security_invoker = true) as
select o.id, o.order_no, o.status, o.ticket_count, o.total_minor, o.currency,
       o.payer_name, o.bank_name, o.payment_ref, o.paid_on,
       o.submitted_at, o.last_submitted_at, o.reviewed_at, o.resubmit_count,
       o.reject_reason_code, o.reject_reason_text, o.review_note, o.receipt_path, o.receipt_mime,
       a.staff_code as reviewer_code,
       p.id as buyer_id, p.public_code as buyer_code, p.full_name as buyer_name, p.email as buyer_email,
       p.phone_e164 as buyer_phone, p.whatsapp_e164 as buyer_whatsapp, p.whatsapp_added_at, p.locale as buyer_locale,
       (select count(*) from public.tickets t where t.order_id = o.id and t.status = 'used') as checked_in_count,
       (select string_agg(t.holder_name, ', ' order by t.seq) from public.tickets t where t.order_id = o.id) as holder_names  -- SD-17
from public.orders o
join public.profiles p on p.id = o.buyer_id
left join public.profiles a on a.id = o.reviewed_by;

-- Orders and tickets are aggregated separately: joining them first multiplied each
-- order's total by its ticket count (SD-10).
create or replace view public.admin_users_v with (security_invoker = true) as
select p.id, p.public_code, p.full_name, p.email, p.phone_e164, p.whatsapp_e164, p.id_number, p.locale, p.status,
       p.whatsapp_added_at, p.created_at,
       coalesce(os.orders, 0) as orders, coalesce(ts.tickets, 0) as tickets,
       coalesce(ts.approved_tickets, 0) as approved_tickets, coalesce(ts.checked_in, 0) as checked_in,
       coalesce(os.paid_minor, 0) as paid_minor, os.last_order_at
from public.profiles p
left join lateral (
  select count(*)                                          as orders,
         sum(o.total_minor) filter (where o.status = 'approved') as paid_minor,
         max(o.created_at)                                 as last_order_at
  from public.orders o where o.buyer_id = p.id) os on true
left join lateral (
  select count(*) filter (where t.status <> 'void')            as tickets,
         count(*) filter (where t.status in ('valid', 'used')) as approved_tickets,
         count(*) filter (where t.status = 'used')             as checked_in
  from public.tickets t where t.buyer_id = p.id) ts on true
where p.role = 'user';

create or replace view public.admin_door_list_v with (security_invoker = true) as
select t.short_code, t.holder_name, t.status, o.order_no, p.full_name as buyer_name, p.phone_e164 as buyer_phone
from public.tickets t join public.orders o on o.id = t.order_id join public.profiles p on p.id = t.buyer_id
where t.status in ('valid', 'used');

---------------------------------------------------------------- analytics (A-4)
create or replace function public.admin_analytics() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r jsonb;
begin
  if not private.is_admin() then raise exception 'FORBIDDEN'; end if;
  select jsonb_build_object(
    'capacity', (select capacity from public.event_config where id = true),
    'tickets_by_status', (select coalesce(jsonb_object_agg(status::text, n), '{}'::jsonb)
                          from (select status, count(*) n from public.tickets group by 1) s),
    'orders_by_status',  (select coalesce(jsonb_object_agg(status::text, jsonb_build_object('orders', n, 'amount_minor', amt)), '{}'::jsonb)
                          from (select status, count(*) n, sum(total_minor) amt from public.orders group by 1) s),
    'turnaround_sec',    (select jsonb_build_object(
                            'p50', percentile_cont(0.5) within group (order by extract(epoch from (reviewed_at - last_submitted_at))),
                            'p90', percentile_cont(0.9) within group (order by extract(epoch from (reviewed_at - last_submitted_at))))
                          from public.orders where reviewed_at is not null),
    'pending_oldest_sec',(select extract(epoch from (now() - min(last_submitted_at))) from public.orders where status = 'submitted'),
    'rejections_by_reason', (select coalesce(jsonb_object_agg(code, n), '{}'::jsonb)
                             from (select coalesce(new_data ->> 'reject_reason_code', 'unknown') code, count(*) n
                                   from public.audit_log where action = 'order.reject' group by 1) s),
    'sales_by_day',      (select coalesce(jsonb_agg(jsonb_build_object('day', d, 'tickets', tk, 'amount_minor', amt) order by d), '[]'::jsonb)
                          from (select (reviewed_at at time zone 'Asia/Colombo')::date d, sum(ticket_count) tk, sum(total_minor) amt
                                from public.orders where status = 'approved' group by 1) s),
    'reviews_by_admin',  (select coalesce(jsonb_agg(jsonb_build_object('staff_code', staff_code, 'approved', ap, 'rejected', rj)), '[]'::jsonb)
                          from (select a.staff_code,
                                       count(*) filter (where o.status = 'approved') ap,
                                       count(*) filter (where o.status = 'rejected') rj
                                from public.orders o join public.profiles a on a.id = o.reviewed_by group by 1) s),
    'checkins_by_gate',  (select coalesce(jsonb_object_agg(coalesce(gate, '-'), n), '{}'::jsonb)
                          from (select checked_in_gate gate, count(*) n from public.tickets where status = 'used' group by 1) s),
    'checkins_per_10min',(select coalesce(jsonb_agg(jsonb_build_object('t', b, 'n', n) order by b), '[]'::jsonb)
                          from (select to_timestamp(floor(extract(epoch from checked_in_at) / 600) * 600) b, count(*) n
                                from public.tickets where status = 'used' group by 1) s)
  ) into r;
  return r;
end $$;

---------------------------------------------------------------- dev health (§16, SD-2)
create or replace function public.dev_health() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_dev() then raise exception 'FORBIDDEN'; end if;
  return jsonb_build_object(
    'outbox', (select coalesce(jsonb_object_agg(status::text, n), '{}'::jsonb) from (select status, count(*) n from public.notification_outbox group by 1) s),
    'outbox_oldest_queued_sec', (select extract(epoch from (now() - min(created_at))) from public.notification_outbox where status in ('queued', 'failed')),
    'orders', (select coalesce(jsonb_object_agg(status::text, n), '{}'::jsonb) from (select status, count(*) n from public.orders group by 1) s),
    'db_bytes', pg_database_size(current_database()),
    'receipt_objects', (select jsonb_build_object('count', count(*), 'bytes', coalesce(sum((metadata ->> 'size')::bigint), 0))
                        from storage.objects where bucket_id = 'receipts'),
    -- SD-2 backstop: who is filling storage
    'top_uploaders', (select coalesce(jsonb_agg(jsonb_build_object('user_code', u.public_code, 'email', u.email,
                                                                    'objects', x.n, 'bytes', x.b) order by x.b desc), '[]'::jsonb)
                      from (select split_part(o.name, '/', 1) uid, count(*) n, coalesce(sum((o.metadata ->> 'size')::bigint), 0) b
                            from storage.objects o where o.bucket_id = 'receipts'
                            group by 1 order by 3 desc limit 10) x
                      left join public.profiles u on u.id::text = x.uid),
    'cron_last_runs', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
                        select j.jobname, d.status, d.start_time from cron.job j
                        join lateral (select * from cron.job_run_details where jobid = j.jobid order by start_time desc limit 1) d on true) x));
end $$;

-- Not reachable from the API until 006 grants each function and view explicitly.
revoke execute on all functions in schema public from public, anon, authenticated;
revoke all on all tables in schema public from anon, authenticated;
