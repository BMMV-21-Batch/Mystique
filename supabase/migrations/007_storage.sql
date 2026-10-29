-- 007: receipts bucket + storage policies (A-08, spec §6.7, SD-2, SD-4)
--
-- Users may ONLY upload into their own folder, as <uid>/<uuid>.<ext>, at most 10 times per
-- rolling 24 h (SD-2). No update or delete policy: receipts are payment evidence and are kept
-- until the post-event purge. Admins read through 60 s signed URLs.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('receipts', 'receipts', false, 2097152,
        array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do nothing;

-- Uploads by this user in the last 24 h. SECURITY DEFINER so the count does not depend
-- on (and cannot recurse into) the storage SELECT policy.
create or replace function private.receipt_uploads_24h(p_user uuid) returns int
language sql stable security definer set search_path = '' as $$
  select count(*)::int from storage.objects
  where bucket_id = 'receipts' and split_part(name, '/', 1) = p_user::text
    and created_at > now() - interval '24 hours'
$$;
revoke execute on function private.receipt_uploads_24h(uuid) from public, anon, authenticated;
grant  execute on function private.receipt_uploads_24h(uuid) to authenticated;

-- Remaining uploads, so the client can show "try again tomorrow" (UPLOAD_LIMIT) before trying.
create or replace function public.my_upload_quota() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('limit', 10, 'used', u, 'remaining', greatest(10 - u, 0))
  from (select private.receipt_uploads_24h(auth.uid()) u) s
  where auth.uid() is not null
$$;
revoke execute on function public.my_upload_quota() from public, anon, authenticated;
grant  execute on function public.my_upload_quota() to authenticated;

create policy receipts_insert_own on storage.objects for insert to authenticated
  with check (
    bucket_id = 'receipts'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and name ~ '^[0-9a-f-]{36}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp|pdf)$'  -- SD-4
    and exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.status = 'active')
    and private.receipt_uploads_24h((select auth.uid())) < 10);                                                 -- SD-2

create policy receipts_select_own_or_admin on storage.objects for select to authenticated
  using (bucket_id = 'receipts'
         and ((storage.foldername(name))[1] = (select auth.uid())::text or (select private.is_admin())));
