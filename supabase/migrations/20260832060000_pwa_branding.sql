-- =============================================================================
-- Decision 51 — the studio's app on the home screen (per-tenant PWA).
--
-- re-issues: studio_by_slug(text)
--
-- Two nullable branding columns on `studios`: the login sub-line and the
-- Install-page welcome. Both default NULL; the app shows a default sentence when
-- unset, so nothing changes for an existing studio. studio_by_slug — the one
-- anon pre-login lookup (migration 004), one of the TWELVE anon surfaces —
-- returns them. It is a `returns table`, so adding columns is a DROP + recreate
-- (a `create or replace` cannot change the output columns), and a drop discards
-- the ACL — re-granted to anon/authenticated/service_role and asserted exactly
-- twelve below.
-- =============================================================================

alter table studios add column if not exists login_tagline  text;
alter table studios add column if not exists install_welcome text;

comment on column studios.login_tagline is
  'Decision 51: the member sign-in sub-line. NULL shows the default sentence.';
comment on column studios.install_welcome is
  'Decision 51: the Install-page welcome line. NULL shows the default sentence.';

drop function if exists studio_by_slug(text);

create function studio_by_slug(p_slug text)
returns table (
  id uuid, name text, slug text, timezone text, currency text,
  logo_url text, theme_preset theme_preset, accent_color text, login_image_url text,
  login_image_focus_x smallint, login_image_focus_y smallint, free_first_class_enabled boolean,
  login_tagline text, install_welcome text
)
language sql stable security definer set search_path = public as $$
  select s.id, s.name, s.slug, s.timezone, s.currency,
         s.logo_url, s.theme_preset, s.accent_color, s.login_image_url,
         s.login_image_focus_x, s.login_image_focus_y,
         coalesce(ss.free_first_class_enabled, false),
         s.login_tagline, s.install_welcome
    from studios s
    left join studio_settings ss on ss.studio_id = s.id
   where s.slug = p_slug and s.status = 'active'
$$;
revoke execute on function studio_by_slug(text) from public;
grant  execute on function studio_by_slug(text) to anon, authenticated, service_role;

-- The anon surface is unchanged — exactly TWELVE pre-login functions. The
-- drop+recreate must not have reopened or lost studio_by_slug's anon grant.
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 12 then
    raise exception 'anon surface is % functions, expected exactly 12', n;
  end if;
end $$;
