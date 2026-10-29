-- Local seed (A-10). Applied by `supabase db reset` only: `db push` never runs it, so it
-- never reaches staging or prod. Everything here is fake.
--
-- Sign in locally with any of these emails; the 6-digit code arrives in the local
-- inbox at http://127.0.0.1:54324. Admin/dev screens additionally need TOTP enrolment.
--   user@mystique.local    plain user, profile complete, two orders
--   buyer2@mystique.local  plain user, one rejected order
--   new@mystique.local     plain user, profile NOT complete (first-purchase flow)
--   admin@mystique.local   admin (A001)
--   admin2@mystique.local  admin (A002), for four-eyes review
--   dev@mystique.local     dev (D001)

------------------------------------------------------------------ event config
insert into public.event_config (name, venue, starts_at, capacity, unit_price_minor, sales_open_at, sales_close_at,
                                 whatsapp_group_url, bank_details)
values ('Mystique 2026 (local)', 'Test venue, Colombo', '2026-12-26 18:00+05:30', 300, 250000,
        now() - interval '1 day', '2026-12-20 23:59+05:30',
        'https://chat.whatsapp.com/LocalTestGroup123',
        '{"bank":"Test Bank","account_name":"Mystique Batch","account_no":"0000000000","branch":"Colombo",
          "note_en":"Use your phone number as the reference.","note_si":"යොමුව ලෙස ඔබගේ දුරකථන අංකය භාවිතා කරන්න."}');

------------------------------------------------------------------ users
-- Shaped like users Auth created itself (confirmed email + an email identity), so OTP login works.
insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data,
                        confirmation_token, recovery_token, email_change_token_new, email_change)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.email, now(), now(), now(),
       '{"provider":"email","providers":["email"]}', jsonb_build_object('locale', u.locale), '', '', '', ''
from (values
  ('10000000-0000-0000-0000-000000000001'::uuid, 'user@mystique.local',   'si'),
  ('10000000-0000-0000-0000-000000000002'::uuid, 'buyer2@mystique.local', 'en'),
  ('10000000-0000-0000-0000-000000000003'::uuid, 'new@mystique.local',    'en'),
  ('10000000-0000-0000-0000-0000000000a1'::uuid, 'admin@mystique.local',  'en'),
  ('10000000-0000-0000-0000-0000000000a2'::uuid, 'admin2@mystique.local', 'en'),
  ('10000000-0000-0000-0000-0000000000d1'::uuid, 'dev@mystique.local',    'en')) as u(id, email, locale);

insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
select gen_random_uuid(), id, id::text, 'email', jsonb_build_object('sub', id::text, 'email', email, 'email_verified', true),
       now(), now(), now()
from auth.users where email like '%@mystique.local';

-- Profiles were created by the trigger; fill in details and roles.
update public.profiles p set full_name = v.name, phone_e164 = v.phone, whatsapp_e164 = v.phone
from (values
  ('10000000-0000-0000-0000-000000000001'::uuid, 'කමල් පෙරේරා',  '+94770000001'),
  ('10000000-0000-0000-0000-000000000002'::uuid, 'Nimali Silva', '+94770000002'),
  ('10000000-0000-0000-0000-0000000000a1'::uuid, 'Admin One',    '+94770000101'),
  ('10000000-0000-0000-0000-0000000000a2'::uuid, 'Admin Two',    '+94770000102'),
  ('10000000-0000-0000-0000-0000000000d1'::uuid, 'Dev One',      '+94770000201')) as v(id, name, phone)
where p.id = v.id;
update public.profiles set role = 'admin', staff_code = 'A' || lpad(nextval('private.staff_seq')::text, 3, '0'),
                           admin_approved_at = now()
 where id in ('10000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-0000000000a2');
update public.profiles set role = 'dev', staff_code = 'D001' where id = '10000000-0000-0000-0000-0000000000d1';

------------------------------------------------------------------ orders (via the real functions)
-- Receipt paths point at no real file: the admin receipt viewer will show "not found" for these.
select public.create_order('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
         '[{"name":"කමල් පෙරේරා"},{"name":"Saman Kumara","phone":"+94771234567"}]',
         'K Perera', 'BOC', 'LOCAL-1001', current_date,
         '10000000-0000-0000-0000-000000000001/30000000-0000-0000-0000-000000000001.jpg', repeat('a', 64), 'image/jpeg', 120000);
select public.create_order('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
         '[{"name":"කමල් පෙරේරා"}]',
         'K Perera', 'BOC', 'LOCAL-1002', current_date,
         '10000000-0000-0000-0000-000000000001/30000000-0000-0000-0000-000000000002.jpg', repeat('b', 64), 'image/jpeg', 98000);
select public.create_order('10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000003',
         '[{"name":"Nimali Silva"},{"name":"Ruwan Silva"},{"name":"Dilani Silva"}]',
         'Nimali Silva', 'Sampath', 'LOCAL-2001', current_date,
         '10000000-0000-0000-0000-000000000002/30000000-0000-0000-0000-000000000003.png', repeat('c', 64), 'image/png', 210000);

-- Review as Admin One (functions check aal2 from the JWT claims).
select set_config('request.jwt.claims', '{"sub":"10000000-0000-0000-0000-0000000000a1","aal":"aal2","role":"authenticated"}', true);
select public.approve_order((select id from public.orders where payment_ref = 'LOCAL1001'), 'See you at the party!');
select public.reject_order((select id from public.orders where payment_ref = 'LOCAL2001'), 'amount_mismatch');
select set_config('request.jwt.claims', '', true);
