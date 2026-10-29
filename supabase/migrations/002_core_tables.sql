-- 002: tables, indexes, rejection reasons, touch triggers (A-03, spec §6.2)
--
-- Every table gets RLS enabled and Supabase's default API grants revoked HERE, so nothing
-- is reachable with the anon/authenticated key until 006 adds the real grants and policies.

-- Code generator for human-friendly ids (no I, L, O, 0, 1). NOT a secret.
create or replace function private.gen_code(prefix text, n int) returns text
language sql volatile as $$
  select prefix || '-' || string_agg(
    substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789', 1 + floor(random() * 31)::int, 1), '')
  from generate_series(1, n)
$$;

create sequence private.staff_seq;

------------------------------------------------------------------ profiles
create table public.profiles (
  id                uuid primary key references auth.users(id) on delete restrict,
  public_code       text not null unique default private.gen_code('U', 6),
  staff_code        text unique,                       -- 'A001' for admins, 'D001' for devs
  role              public.user_role not null default 'user',
  status            public.account_status not null default 'active',
  email             text not null unique check (email = lower(email)),
  full_name         text check (char_length(full_name) between 2 and 80),
  phone_e164        text unique check (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  whatsapp_e164     text check (whatsapp_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  id_number         text unique check (char_length(id_number) between 3 and 30),
  locale            text not null default 'en' check (locale in ('si', 'en')),
  admin_requested_at timestamptz,
  admin_approved_by uuid references public.profiles(id),
  admin_approved_at timestamptz,
  whatsapp_added_at timestamptz,                        -- set by admin (A-6)
  whatsapp_added_by uuid references public.profiles(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index profiles_name_trgm  on public.profiles using gin (full_name extensions.gin_trgm_ops);
create index profiles_email_trgm on public.profiles using gin (email extensions.gin_trgm_ops);
-- (no separate phone index: the unique constraint already indexes phone_e164)
create index profiles_role_idx   on public.profiles (role) where role <> 'user';

---------------------------------------------------------------- event_config
create table public.event_config (
  id                     boolean primary key default true check (id),   -- singleton row
  name                   text not null,
  venue                  text,
  starts_at              timestamptz not null,
  capacity               int  not null check (capacity > 0),
  unit_price_minor       int  not null check (unit_price_minor >= 0),    -- LKR cents
  currency               char(3) not null default 'LKR',
  sales_open_at          timestamptz not null,
  sales_close_at         timestamptz not null,
  sales_paused           boolean not null default false,
  max_tickets_per_order  int not null default 10 check (max_tickets_per_order between 1 and 50),
  max_tickets_per_account int not null default 20,
  rejected_hold_minutes  int not null default 1440,   -- seats held 24h after a rejection
  max_resubmits          int not null default 3,
  whatsapp_group_url     text check (whatsapp_group_url is null
                                     or whatsapp_group_url ~ '^https://chat\.whatsapp\.com/[A-Za-z0-9]+$'),
  bank_details           jsonb not null default '{}',  -- {"bank","account_name","account_no","branch","note_en","note_si"}
  updated_at             timestamptz not null default now(),
  updated_by             uuid references public.profiles(id)
);

------------------------------------------------------------ rejection_reasons
create table public.rejection_reasons (
  code      text primary key,
  label_en  text not null,
  label_si  text not null,
  sort      int  not null default 0,
  active    boolean not null default true
);
insert into public.rejection_reasons (code, label_en, label_si, sort) values
 ('amount_mismatch',   'Amount does not match the order total',  'මුදල ඇණවුමේ මුළු මුදලට නොගැලපේ', 1),
 ('receipt_unreadable','Receipt is unclear or unreadable',       'රිසිට්පත පැහැදිලි නැත',            2),
 ('payment_not_found', 'Payment not found in our account',       'අපගේ ගිණුමේ ගෙවීම සොයාගත නොහැක',  3),
 ('wrong_account',     'Paid to a different account',            'වෙනත් ගිණුමකට ගෙවා ඇත',            4),
 ('other',             'Other (see note)',                       'වෙනත් (සටහන බලන්න)',               9);

-------------------------------------------------------------------- orders
create table public.orders (
  id                uuid primary key default gen_random_uuid(),
  order_no          text not null unique default private.gen_code('ORD', 6),
  buyer_id          uuid not null references public.profiles(id),
  status            public.order_status not null default 'submitted',
  ticket_count      int  not null check (ticket_count between 1 and 50),
  unit_price_minor  int  not null,
  total_minor       int  not null check (total_minor >= 0),
  currency          char(3) not null default 'LKR',
  -- payment claim by the buyer
  payer_name        text not null,
  bank_name         text,
  payment_ref       text not null,        -- normalised: upper-case, A-Z0-9 only
  paid_on           date,
  -- receipt (verified server-side)
  receipt_path      text not null,
  receipt_sha256    char(64) not null,
  receipt_mime      text not null,
  receipt_bytes     int  not null,
  -- review
  reviewed_by       uuid references public.profiles(id),
  reviewed_at       timestamptz,
  review_note       text,
  reject_reason_code text references public.rejection_reasons(code),
  reject_reason_text text,
  hold_expires_at   timestamptz,          -- only while rejected
  resubmit_count    int not null default 0,
  idempotency_key   uuid not null,
  submitted_at      timestamptz not null default now(),
  last_submitted_at timestamptz not null default now(),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint orders_idem_uk unique (buyer_id, idempotency_key),
  constraint orders_reject_has_reason check (status <> 'rejected' or reject_reason_code is not null),
  constraint orders_reject_other_has_text check (reject_reason_code <> 'other' or char_length(coalesce(reject_reason_text, '')) >= 3)
);
-- The same slip / reference cannot back two live orders (A-3 anti-fraud)
create unique index orders_active_receipt_uk on public.orders (receipt_sha256)
  where status in ('submitted', 'approved');
create unique index orders_active_payref_uk  on public.orders (payment_ref)
  where status in ('submitted', 'approved');
create index orders_status_submitted_idx on public.orders (status, last_submitted_at);
create index orders_buyer_idx            on public.orders (buyer_id, created_at desc);
create index orders_payref_trgm          on public.orders using gin (payment_ref extensions.gin_trgm_ops);

------------------------------------------------------------------- tickets
create table public.tickets (
  id              uuid primary key default gen_random_uuid(),
  order_id        uuid not null references public.orders(id) on delete cascade,
  buyer_id        uuid not null references public.profiles(id),   -- denormalised for RLS
  seq             smallint not null,
  short_code      text not null unique default private.gen_code('T', 6),   -- manual lookup at the gate
  holder_name     text not null check (char_length(holder_name) between 2 and 80),
  holder_phone    text,
  status          public.ticket_status not null default 'pending',
  qr_version      smallint not null default 1,          -- bump to invalidate and reissue a QR
  checked_in_at   timestamptz,
  checked_in_by   uuid references public.profiles(id),
  checked_in_gate text,
  void_reason     text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint tickets_order_seq_uk unique (order_id, seq),
  constraint tickets_used_has_time check ((status = 'used') = (checked_in_at is not null))
);
create index tickets_buyer_idx  on public.tickets (buyer_id);
create index tickets_active_idx on public.tickets (status) where status <> 'void';   -- capacity count
create index tickets_name_trgm  on public.tickets using gin (holder_name extensions.gin_trgm_ops);

---------------------------------------------------------------- audit_log
create table public.audit_log (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  actor_id    uuid,
  actor_role  text,
  action      text not null,                  -- 'order.approve', 'ticket.check_in', 'admin.grant' …
  entity_type text not null,
  entity_id   text,
  old_data    jsonb,
  new_data    jsonb,
  meta        jsonb not null default '{}',
  ip          text,                           -- text on purpose: a malformed header must never break a write
  request_id  text
);
create index audit_at_idx     on public.audit_log (at desc);
create index audit_entity_idx on public.audit_log (entity_type, entity_id);
create index audit_actor_idx  on public.audit_log (actor_id, at desc);

------------------------------------------------------------------ scan_log
create table public.scan_log (
  id           bigint generated always as identity primary key,
  ticket_id    uuid references public.tickets(id),
  result       public.scan_result not null,
  scanned_by   uuid references public.profiles(id),
  gate         text,
  device_id    text,
  offline      boolean not null default false,
  scanned_at   timestamptz not null,
  received_at  timestamptz not null default now()
);
create index scan_log_ticket_idx on public.scan_log (ticket_id, scanned_at);
create index scan_log_time_idx   on public.scan_log (scanned_at);

------------------------------------------------------- notification_outbox
create table public.notification_outbox (
  id              bigint generated always as identity primary key,
  dedupe_key      text not null unique,        -- '<kind>:<order_id>:<resubmit_count>'
  kind            text not null check (kind in
                    ('order_received', 'order_approved', 'order_rejected', 'order_resubmitted', 'order_expired')),
  user_id         uuid references public.profiles(id),
  to_email        text not null,
  locale          text not null default 'en',
  payload         jsonb not null,
  status          public.notif_status not null default 'queued',
  attempts        int  not null default 0,
  next_attempt_at timestamptz not null default now(),
  claimed_at      timestamptz,
  last_error      text,
  created_at      timestamptz not null default now(),
  sent_at         timestamptz
);
create index outbox_due_idx on public.notification_outbox (next_attempt_at)
  where status in ('queued', 'failed');

-- touch updated_at
create or replace function private.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
create trigger t_profiles_touch before update on public.profiles for each row execute function private.touch_updated_at();
create trigger t_orders_touch   before update on public.orders   for each row execute function private.touch_updated_at();
create trigger t_tickets_touch  before update on public.tickets  for each row execute function private.touch_updated_at();

-- Locked down until 006: RLS on with no policies (deny all), no API grants.
alter table public.profiles            enable row level security;
alter table public.event_config        enable row level security;
alter table public.rejection_reasons   enable row level security;
alter table public.orders              enable row level security;
alter table public.tickets             enable row level security;
alter table public.audit_log           enable row level security;
alter table public.scan_log            enable row level security;
alter table public.notification_outbox enable row level security;
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
