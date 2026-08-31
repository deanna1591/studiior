-- =============================================================================
-- MIGRATION 029 — studio branding for the member app
--
-- A studio brands what its members see. The staff app keeps Studiior's lime:
-- it is our back office, not theirs, and theming it would mean every support
-- conversation starts with "what does yours look like".
--
-- Four presets, each a complete surface system rather than a colour swap, and
-- one accent the studio picks. The accent is stored raw and a ramp is DERIVED
-- from it at render — raw for large fills, darkened until it clears 4.5:1 for
-- text, 12% over the surface for a tint. Same method as --amber-deep.
--
-- The derivation lives in lib/theme.ts and not here, deliberately: the picker's
-- live preview and the member app must show the same colours, and two
-- implementations of the same contrast walk would eventually disagree. This
-- migration stores what the studio chose; TypeScript decides what that means.
-- =============================================================================

create type theme_preset as enum ('warm', 'clean', 'calm', 'bold');

alter table studios
  add column theme_preset theme_preset not null default 'warm',
  add column accent_color text,
  add column login_image_url text;

-- Stored uppercase and shaped, so a preview cannot be handed '#GGG' or 'red'
-- and quietly render the fallback while the studio believes it saved.
alter table studios
  add constraint studios_accent_hex
  check (accent_color is null or accent_color ~ '^#[0-9A-F]{6}$');

comment on column studios.accent_color is
  'One hex, as chosen. The accessible ramp is derived from it (lib/theme.ts) — '
  'never use this raw for text.';
comment on column studios.brand_color is
  'Dead. Superseded by accent_color, which is shape-checked and has a derived '
  'ramp. Nothing reads this; left in place because dropping a column from an '
  'applied migration is not worth the churn.';

-- studio_by_slug() is the pre-login lookup and now has to carry the branding,
-- because the login screen and the tab title are both branded before anyone is
-- signed in. Fixed forward — 004 is long applied.
drop function if exists studio_by_slug(text);
create function studio_by_slug(p_slug text)
returns table (
  id uuid, name text, slug text, timezone text, currency text,
  logo_url text, theme_preset theme_preset, accent_color text, login_image_url text
)
language sql stable security definer set search_path = public as $$
  select s.id, s.name, s.slug, s.timezone, s.currency,
         s.logo_url, s.theme_preset, s.accent_color, s.login_image_url
    from studios s
   where s.slug = p_slug and s.status = 'active'
$$;
revoke execute on function studio_by_slug(text) from public;
grant execute on function studio_by_slug(text) to anon, authenticated, service_role;

-- Branding is studio identity, not member administration: Owner only. Decision
-- 8's last-owner rule is the precedent for studio-level settings sitting above
-- Manager.
create policy studios_owner_brand on studios
  for update using (auth_role_in(id) = 'owner')
  with check (auth_role_in(id) = 'owner');

-- -----------------------------------------------------------------------------
-- Where the logo lives
--
-- Public read, because a member's phone fetches it before they sign in. Writes
-- are scoped to owners of the studio whose id is the FIRST PATH SEGMENT, so a
-- studio cannot upload into another studio's folder even with a valid session.
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('studio-branding', 'studio-branding', true, 2097152,
        array['image/png','image/jpeg','image/webp','image/svg+xml'])
on conflict (id) do nothing;

create policy "branding is publicly readable"
  on storage.objects for select
  using (bucket_id = 'studio-branding');

create policy "owners write their own studio's branding"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'studio-branding'
    and auth_role_in((storage.foldername(name))[1]::uuid) = 'owner'
  );

create policy "owners replace their own studio's branding"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'studio-branding'
    and auth_role_in((storage.foldername(name))[1]::uuid) = 'owner'
  );

create policy "owners delete their own studio's branding"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'studio-branding'
    and auth_role_in((storage.foldername(name))[1]::uuid) = 'owner'
  );
