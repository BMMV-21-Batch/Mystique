-- 004: public info, profile, orders (A-05, spec §6.4, SD-5, SD-11, SD-14)
--
-- Every write function refuses suspended accounts with ACCOUNT_SUSPENDED (SD-5), except
-- set_my_locale: a language preference is harmless, and blocking it would break the toggle.
-- Bad input that trips a table constraint is reported as VALIDATION, never a raw error (SD-14).

---------------------------------------------------------------- public info
create or replace function public.get_public_event() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'name', c.name, 'venue', c.venue, 'starts_at', c.starts_at,
    'unit_price_minor', c.unit_price_minor, 'currency', c.currency,
    'sales_open_at', c.sales_open_at, 'sales_close_at', c.sales_close_at, 'sales_paused', c.sales_paused,
    'max_tickets_per_order', c.max_tickets_per_order,
    'sold_out', (select count(*) from public.tickets where status <> 'void') >= c.capacity)
  from public.event_config c where c.id = true
$$;

-- bank details: logged-in users only
create or replace function public.get_payment_instructions() returns jsonb
language sql stable security definer set search_path = '' as $$
  select c.bank_details from public.event_config c where c.id = true and auth.uid() is not null
$$;

-- WhatsApp group link: only for users who have at least one live order (ADR-5)
create or replace function public.get_whatsapp_group() returns text
language sql stable security definer set search_path = '' as $$
  select c.whatsapp_group_url from public.event_config c
  where c.id = true and exists (select 1 from public.orders o
                                where o.buyer_id = auth.uid() and o.status in ('submitted', 'approved', 'rejected'))
$$;

---------------------------------------------------------------- profile
create or replace function public.update_my_profile(
  p_full_name text, p_phone_e164 text, p_whatsapp_e164 text, p_id_number text, p_locale text)
returns public.profiles language plpgsql security definer set search_path = '' as $$
declare v_old public.profiles; v_new public.profiles; v_c text;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_old from public.profiles where id = auth.uid() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_old.status <> 'active' then raise exception 'ACCOUNT_SUSPENDED'; end if;
  begin
    update public.profiles set
      full_name     = normalize(btrim(p_full_name), NFC),
      phone_e164    = p_phone_e164,
      whatsapp_e164 = coalesce(p_whatsapp_e164, p_phone_e164),
      id_number     = nullif(btrim(p_id_number), ''),
      locale        = case when p_locale in ('si', 'en') then p_locale else locale end
    where id = auth.uid() returning * into v_new;
  exception
    when unique_violation then
      get stacked diagnostics v_c = constraint_name;
      if v_c like '%phone%' then raise exception 'PHONE_TAKEN'; end if;
      if v_c like '%id_number%' then raise exception 'ID_NUMBER_TAKEN'; end if;
      raise;
    when check_violation then raise exception 'VALIDATION';
  end;
  perform private.audit('profile.update', 'profile', auth.uid()::text, to_jsonb(v_old), to_jsonb(v_new));
  return v_new;
end $$;

-- Language toggle: changes ONLY the locale (SD-11; update_my_profile would overwrite every field).
create or replace function public.set_my_locale(p_locale text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_locale is null or p_locale not in ('si', 'en') then raise exception 'VALIDATION'; end if;
  update public.profiles set locale = p_locale where id = auth.uid() and locale <> p_locale;
end $$;

create or replace function public.request_admin_access() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  update public.profiles set admin_requested_at = coalesce(admin_requested_at, now())
  where id = auth.uid() and role = 'user' and status = 'active';
  if found then
    perform private.audit('admin.request', 'profile', auth.uid()::text, null, null);
  end if;
end $$;

---------------------------------------------------------------- create_order
-- Called ONLY by the submit-order Edge Function (service_role), after receipt verification.
create or replace function public.create_order(
  p_buyer_id        uuid,
  p_idempotency_key uuid,
  p_holders         jsonb,        -- [{"name":"…","phone":"…"}, …] (first = buyer by convention)
  p_payer_name      text,
  p_bank_name       text,
  p_payment_ref     text,
  p_paid_on         date,
  p_receipt_path    text,
  p_receipt_sha256  text,
  p_receipt_mime    text,
  p_receipt_bytes   int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  cfg      public.event_config;
  v_ex     public.orders;
  v_buyer  public.profiles;
  v_n      int;
  v_taken  int;
  v_mine   int;
  v_ref    text := regexp_replace(upper(coalesce(p_payment_ref, '')), '[^A-Z0-9]', '', 'g');
  v_order  public.orders;
  v_c      text;
begin
  set local lock_timeout = '3s';

  -- 1. Serialise every purchase on the single config row (capacity is checked under this lock).
  select * into cfg from public.event_config where id = true for update;
  if not found then raise exception 'SALES_CLOSED'; end if;

  -- 2. Idempotent replay. Checked AFTER the lock so two concurrent identical requests cannot both pass.
  select * into v_ex from public.orders where buyer_id = p_buyer_id and idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('order_id', v_ex.id, 'order_no', v_ex.order_no, 'status', v_ex.status, 'replayed', true);
  end if;

  -- 3. Validation
  if coalesce(jsonb_typeof(p_holders), '') <> 'array' then raise exception 'VALIDATION'; end if;
  if char_length(v_ref) < 4 then raise exception 'VALIDATION'; end if;   -- SD-14: '' would collide for everyone
  v_n := jsonb_array_length(p_holders);
  select * into v_buyer from public.profiles where id = p_buyer_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_buyer.status <> 'active' then raise exception 'ACCOUNT_SUSPENDED'; end if;
  if v_buyer.full_name is null or v_buyer.phone_e164 is null then raise exception 'PROFILE_INCOMPLETE'; end if;
  if cfg.sales_paused or now() < cfg.sales_open_at or now() > cfg.sales_close_at then raise exception 'SALES_CLOSED'; end if;
  if v_n < 1 or v_n > cfg.max_tickets_per_order then raise exception 'TOO_MANY_TICKETS_IN_ORDER'; end if;
  if (select count(*) from public.orders where buyer_id = p_buyer_id and created_at > now() - interval '1 hour') >= 5
    then raise exception 'RATE_LIMITED'; end if;
  select count(*) into v_mine  from public.tickets where buyer_id = p_buyer_id and status <> 'void';
  if v_mine + v_n > cfg.max_tickets_per_account then raise exception 'ACCOUNT_LIMIT'; end if;

  -- 4. Capacity: seats = every non-void ticket (pending, valid, used)
  select count(*) into v_taken from public.tickets where status <> 'void';
  if v_taken + v_n > cfg.capacity then raise exception 'CAPACITY_EXCEEDED'; end if;

  -- 5. Insert order + tickets (one transaction)
  begin
    insert into public.orders (buyer_id, ticket_count, unit_price_minor, total_minor, currency,
                               payer_name, bank_name, payment_ref, paid_on,
                               receipt_path, receipt_sha256, receipt_mime, receipt_bytes, idempotency_key)
    values (p_buyer_id, v_n, cfg.unit_price_minor, cfg.unit_price_minor * v_n, cfg.currency,
            normalize(btrim(p_payer_name), NFC), nullif(btrim(p_bank_name), ''), v_ref, p_paid_on,
            p_receipt_path, p_receipt_sha256, p_receipt_mime, p_receipt_bytes, p_idempotency_key)
    returning * into v_order;

    insert into public.tickets (order_id, buyer_id, seq, holder_name, holder_phone)
    select v_order.id, p_buyer_id, h.ord::smallint,
           normalize(btrim(h.val ->> 'name'), NFC), nullif(btrim(h.val ->> 'phone'), '')
    from jsonb_array_elements(p_holders) with ordinality as h(val, ord);
  exception
    when unique_violation then
      get stacked diagnostics v_c = constraint_name;
      if v_c = 'orders_active_receipt_uk' then raise exception 'DUPLICATE_RECEIPT'; end if;
      if v_c = 'orders_active_payref_uk'  then raise exception 'DUPLICATE_PAYMENT_REF'; end if;
      raise;
    when check_violation or not_null_violation then raise exception 'VALIDATION';   -- SD-14
  end;

  perform private.audit('order.create', 'order', v_order.id::text, null, to_jsonb(v_order), '{}'::jsonb, p_buyer_id);
  perform private.enqueue_order_mail(v_order.id, 'order_received');

  return jsonb_build_object('order_id', v_order.id, 'order_no', v_order.order_no,
                            'status', v_order.status, 'replayed', false);
end $$;

---------------------------------------------------------------- resubmit_order
-- Called ONLY by the resubmit-order Edge Function (service_role).
create or replace function public.resubmit_order(
  p_buyer_id uuid, p_order_id uuid, p_payer_name text, p_bank_name text, p_payment_ref text,
  p_paid_on date, p_receipt_path text, p_receipt_sha256 text, p_receipt_mime text, p_receipt_bytes int)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare cfg public.event_config; o public.orders; v_old public.orders; v_c text;
        v_ref text := regexp_replace(upper(coalesce(p_payment_ref, '')), '[^A-Z0-9]', '', 'g');
begin
  set local lock_timeout = '3s';
  select * into cfg from public.event_config where id = true;           -- read only
  if exists (select 1 from public.profiles where id = p_buyer_id and status <> 'active')
    then raise exception 'ACCOUNT_SUSPENDED'; end if;
  select * into o from public.orders where id = p_order_id and buyer_id = p_buyer_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if o.status <> 'rejected'          then raise exception 'INVALID_TRANSITION'; end if;
  if o.hold_expires_at <= now()      then raise exception 'HOLD_EXPIRED'; end if;
  if o.resubmit_count >= cfg.max_resubmits then raise exception 'RESUBMIT_LIMIT'; end if;
  if char_length(v_ref) < 4 then raise exception 'VALIDATION'; end if;   -- SD-14
  v_old := o;
  begin
    update public.orders set
      status = 'submitted', payer_name = normalize(btrim(p_payer_name), NFC), bank_name = nullif(btrim(p_bank_name), ''),
      payment_ref = v_ref, paid_on = p_paid_on, receipt_path = p_receipt_path, receipt_sha256 = p_receipt_sha256,
      receipt_mime = p_receipt_mime, receipt_bytes = p_receipt_bytes,
      resubmit_count = resubmit_count + 1, last_submitted_at = now(),
      hold_expires_at = null, reject_reason_code = null, reject_reason_text = null
    where id = o.id returning * into o;
  exception
    when unique_violation then
      get stacked diagnostics v_c = constraint_name;
      if v_c = 'orders_active_receipt_uk' then raise exception 'DUPLICATE_RECEIPT'; end if;
      if v_c = 'orders_active_payref_uk'  then raise exception 'DUPLICATE_PAYMENT_REF'; end if;
      raise;
    when check_violation or not_null_violation then raise exception 'VALIDATION';   -- SD-14
  end;
  perform private.audit('order.resubmit', 'order', o.id::text, to_jsonb(v_old), to_jsonb(o), '{}'::jsonb, p_buyer_id);
  perform private.enqueue_order_mail(o.id, 'order_resubmitted');
  return jsonb_build_object('order_id', o.id, 'status', o.status, 'old_receipt_path', v_old.receipt_path);
end $$;

---------------------------------------------------------------- cancel (user)
create or replace function public.cancel_my_order(p_order_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare o public.orders; v_old public.orders;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if exists (select 1 from public.profiles where id = auth.uid() and status <> 'active')
    then raise exception 'ACCOUNT_SUSPENDED'; end if;
  select * into o from public.orders where id = p_order_id and buyer_id = auth.uid() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if o.status not in ('submitted', 'rejected') then raise exception 'INVALID_TRANSITION'; end if;
  v_old := o;
  update public.orders set status = 'cancelled', hold_expires_at = null where id = o.id returning * into o;
  update public.tickets set status = 'void', void_reason = 'order_cancelled' where order_id = o.id and status = 'pending';
  perform private.audit('order.cancel', 'order', o.id::text, to_jsonb(v_old), to_jsonb(o));
end $$;

---------------------------------------------------------------- QR payloads (owner or admin)
create or replace function public.my_order_tickets(p_order_id uuid)
returns table (ticket_id uuid, seq smallint, holder_name text, short_code text, status public.ticket_status, qr text)
language sql stable security definer set search_path = '' as $$
  select t.id, t.seq, t.holder_name, t.short_code, t.status, private.qr_payload(t.id, t.qr_version)
  from public.tickets t
  where t.order_id = p_order_id and t.status <> 'void'
    and (t.buyer_id = auth.uid() or private.is_admin())
  order by t.seq
$$;

-- Not callable from the API until 006 grants each function explicitly.
revoke execute on all functions in schema public from public, anon, authenticated;
