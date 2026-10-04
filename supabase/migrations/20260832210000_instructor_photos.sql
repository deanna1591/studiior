-- Decision 60 — an instructor's photo is uploaded, not linked.
--
-- creates: (no functions — a public storage bucket + four storage policies only)
-- re-issues: (none)
--
-- A new PUBLIC bucket `instructor-photos`, files at {studio_id}/{instructor_id}/
-- {timestamp}.{ext}. The saved PUBLIC url goes into the existing
-- instructors.avatar_url, so every reader that already shows the photo (the
-- member booking list and class page, the Home card, the instructor roster,
-- public_schedule and the website embed) shows it with no change — a
-- Supabase public-object url is absolute and the embed uses it verbatim.
--
-- Writes: a MANAGER of the path's studio, OR the instructor themselves. The
-- self-branch does NOT call instructor_user_id (that function is not granted to
-- `authenticated` — granting it would add an unguarded, data-returning authed
-- surface, the migration-056 shape). Instead it inlines the instructors ->
-- studio_staff join under the caller's own RLS visibility plus auth.uid(),
-- exactly the member-avatar policy pattern (migration 450000): an
-- instructor-with-login is staff, so instructors_staff_read / studio_staff
-- staff_read make their OWN rows visible and nobody else's path[2] matches.
-- A pure member is not staff, so studio_staff is invisible to them and the
-- EXISTS is empty; staff of another studio cannot see the path's studio at all.
--
-- Reads: public, like studio-branding's logo — the photo is on the studio's
-- public website by design. The bucket is public=true so getPublicUrl serves
-- it without a session; the select policy mirrors the branding one for parity.
--
-- No function is created or re-issued, so there is no new anon/authed RPC
-- surface (the anon RPC count stays exactly thirteen — a storage bucket is not
-- an RPC). Decision 18 untouched.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('instructor-photos', 'instructor-photos', true, 5242880,
        array['image/png','image/jpeg','image/webp'])
on conflict (id) do nothing;

drop policy if exists "instructor photos are publicly readable" on storage.objects;
create policy "instructor photos are publicly readable"
  on storage.objects for select
  using (bucket_id = 'instructor-photos');

drop policy if exists "managers or the instructor write instructor photos" on storage.objects;
create policy "managers or the instructor write instructor photos"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'instructor-photos'
    and (
      is_manager_up((storage.foldername(name))[1]::uuid)
      or exists (
        select 1
          from instructors i
          join studio_staff ss on ss.id = i.staff_id
         where i.id = (storage.foldername(name))[2]::uuid
           and i.studio_id = (storage.foldername(name))[1]::uuid
           and ss.user_id = auth.uid()
           and ss.status = 'active'
      )
    )
  );

drop policy if exists "managers or the instructor replace instructor photos" on storage.objects;
create policy "managers or the instructor replace instructor photos"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'instructor-photos'
    and (
      is_manager_up((storage.foldername(name))[1]::uuid)
      or exists (
        select 1
          from instructors i
          join studio_staff ss on ss.id = i.staff_id
         where i.id = (storage.foldername(name))[2]::uuid
           and i.studio_id = (storage.foldername(name))[1]::uuid
           and ss.user_id = auth.uid()
           and ss.status = 'active'
      )
    )
  );

drop policy if exists "managers or the instructor delete instructor photos" on storage.objects;
create policy "managers or the instructor delete instructor photos"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'instructor-photos'
    and (
      is_manager_up((storage.foldername(name))[1]::uuid)
      or exists (
        select 1
          from instructors i
          join studio_staff ss on ss.id = i.staff_id
         where i.id = (storage.foldername(name))[2]::uuid
           and i.studio_id = (storage.foldername(name))[1]::uuid
           and ss.user_id = auth.uid()
           and ss.status = 'active'
      )
    )
  );
