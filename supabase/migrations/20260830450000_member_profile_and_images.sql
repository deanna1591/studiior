-- =============================================================================
-- Migration 035: a member's own profile, and the hole under it
-- =============================================================================
-- Asked whether members.avatar_url is member-writable. It is — and so is every
-- other column on the row. `members_self_update` is
--
--     using (user_id = auth.uid()) with check (user_id = auth.uid())
--
-- with no column restriction, and `authenticated` holds UPDATE on all 28
-- columns. RLS is row-level: it decides WHICH rows, never which columns. Proved
-- against the seeded member who has no signed waiver:
--
--     book_class -> waiver_not_signed
--     update members set waiver_signed_at = now(), status = 'active' ...
--     book_class -> booked
--
-- She signed her own waiver and promoted herself from lead to active. The
-- waiver is the studio's legal position on somebody getting hurt, and §2.1
-- rule 4 is the only thing enforcing it. `health_band`, `lifetime_visits`,
-- `is_demo` and `studio_id` were equally open.
--
-- COLUMN GRANTS CANNOT FIX THIS. The obvious repair — revoke UPDATE and
-- re-grant it on the handful of profile columns — applies to the ROLE, and
-- front desk, managers and members are all `authenticated`. Narrowing the
-- grant would take the same columns away from the staff who are supposed to
-- edit them.
--
-- So the rule goes in a trigger, where it applies to every present and future
-- call site rather than to the one screen I happen to be adding. It compares
-- the whole row minus the fields a member owns: anything not on that list is
-- protected by default, so a column added next year is closed the day it is
-- created rather than the day somebody remembers it.
-- =============================================================================

alter table members add column if not exists preferred_name text;
comment on column members.preferred_name is
  'What they want to be called, when that is not their first name. Shown in the '
  'app greeting and on the staff roster; first_name stays the legal-ish one that '
  'matches their payment records.';

alter table class_types add column if not exists image_url text;
comment on column class_types.image_url is
  'A photograph of the class, shown on the member''s class cards and detail '
  'screen. Public: it lives in studio-branding beside the logo, because it is '
  'studio marketing rather than anybody''s personal data.';

-- -----------------------------------------------------------------------------
-- What a member may change about themselves
-- -----------------------------------------------------------------------------
create or replace function guard_member_self_update() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  -- Everything else on the row is protected. Adding a column adds it to the
  -- protected set automatically, which is the right default for this table.
  owned constant text[] := array[
    'preferred_name', 'phone', 'avatar_url', 'emergency_contact',
    'address', 'date_of_birth', 'marketing_opt_in', 'updated_at'
  ];
begin
  -- The background jobs: the nightly health pass and the check-in trigger both
  -- write here with no JWT at all. is_service_context() asks Postgres whether
  -- the effective role is one it marks superuser or bypassrls, so it is true
  -- for cron and can never be true for a signed-in member (migration 024).
  if is_service_context() then
    return new;
  end if;

  -- Front desk and up may edit a member; that is their job (Permissions §5).
  if is_desk_up(new.studio_id) then
    return new;
  end if;

  -- The account-claim path, where user_id goes from null to the caller.
  -- members_self_claim already constrains it with its own WITH CHECK, and the
  -- row is not yet anybody's to protect.
  if old.user_id is null then
    return new;
  end if;

  -- Anything else is not a member editing their own row — members_self_update
  -- is the only policy that would have let it through, and it requires exactly
  -- this match. Leave the decision to RLS.
  if auth.uid() is null or old.user_id is distinct from auth.uid() then
    return new;
  end if;

  if (to_jsonb(new) - owned) <> (to_jsonb(old) - owned) then
    raise exception 'a member may change their own contact details, not their membership'
      using errcode = 'PT403',
            hint = 'Editable by the member: ' || array_to_string(owned, ', ')
                   || '. Everything else is the studio''s to set.';
  end if;

  return new;
end $$;

drop trigger if exists members_self_update_guard on members;
create trigger members_self_update_guard
  before update on members
  for each row execute function guard_member_self_update();

revoke execute on function guard_member_self_update() from public, anon, authenticated;

comment on function guard_member_self_update() is
  'Members may edit their own contact details and nothing else. RLS decides '
  'which rows, never which columns, and members_self_update let a member sign '
  'their own waiver and promote themselves to active. Column grants cannot fix '
  'it because staff and members share the authenticated role.';

-- -----------------------------------------------------------------------------
-- Somewhere to put a member's photograph
--
-- A separate bucket from studio-branding, and PRIVATE, which studio-branding is
-- not. A logo and a class photograph are things a studio publishes; a member's
-- face is not. The tenant-one studio is the founder's own and its data is
-- production data, so this starts closed and is read through a signed URL by
-- the two parties with a reason to see it: the member, and the studio's staff.
--
-- The write policy keys on the MEMBER id in the first path segment, the same
-- shape as migration 029's studio prefix, and joins back to members to check
-- the caller owns that row. A member uploads their photograph and nobody
-- else's, whatever the application does.
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('member-avatars', 'member-avatars', false, 2097152,
        array['image/png','image/jpeg','image/webp'])
on conflict (id) do nothing;

drop policy if exists "members write their own avatar" on storage.objects;
create policy "members write their own avatar"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'member-avatars'
    and exists (
      select 1 from members m
       where m.id = (storage.foldername(name))[1]::uuid
         and m.user_id = auth.uid()
    )
  );

drop policy if exists "members replace their own avatar" on storage.objects;
create policy "members replace their own avatar"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'member-avatars'
    and exists (
      select 1 from members m
       where m.id = (storage.foldername(name))[1]::uuid
         and m.user_id = auth.uid()
    )
  );

drop policy if exists "members delete their own avatar" on storage.objects;
create policy "members delete their own avatar"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'member-avatars'
    and exists (
      select 1 from members m
       where m.id = (storage.foldername(name))[1]::uuid
         and m.user_id = auth.uid()
    )
  );

-- Read: the member themselves, and the studio's staff — an instructor needs to
-- recognise who they are teaching, which is the whole point of the photograph.
-- Not the world: this bucket is private and every read is a signed URL.
drop policy if exists "a member avatar is readable by its owner and studio staff" on storage.objects;
create policy "a member avatar is readable by its owner and studio staff"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'member-avatars'
    and exists (
      select 1 from members m
       where m.id = (storage.foldername(name))[1]::uuid
         and (m.user_id = auth.uid() or is_desk_up(m.studio_id))
    )
  );

-- -----------------------------------------------------------------------------
-- Class-type images live in studio-branding, which only owners may write to
--
-- Permissions §4 gives class types to Owner AND Manager, so a manager uploading
-- a class photograph would have been refused by migration 029's owner-only
-- policy — the screen would have offered an upload that always failed. Scoped
-- to a class-types/ folder so this does not quietly widen who can replace the
-- studio's logo.
-- -----------------------------------------------------------------------------
drop policy if exists "managers write class type images" on storage.objects;
create policy "managers write class type images"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'studio-branding'
    and (storage.foldername(name))[2] = 'class-types'
    and is_manager_up((storage.foldername(name))[1]::uuid)
  );

drop policy if exists "managers replace class type images" on storage.objects;
create policy "managers replace class type images"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'studio-branding'
    and (storage.foldername(name))[2] = 'class-types'
    and is_manager_up((storage.foldername(name))[1]::uuid)
  );
