-- =============================================================================
-- 238 — Decision 52a: native store apps — per-tenant verification identifiers.
--
-- Each tenant can have a thin store shell over its member web app. The web app
-- serves the store-verification files (/.well-known/assetlinks.json and
-- /.well-known/apple-app-site-association) per tenant, driven by four nullable,
-- owner-editable columns on studios. No new anon RPC — studio_by_slug (already
-- one of the thirteen anon surfaces) is re-issued to carry the four columns, so
-- the public route handlers read them through it. Anon stays EXACTLY THIRTEEN.
--
-- re-issues: studio_by_slug(text)
-- =============================================================================

alter table studios
  add column if not exists android_package text,
  add column if not exists android_sha256_fingerprints text,  -- comma-separated, upper-hex
  add column if not exists ios_team_id text,
  add column if not exists ios_bundle_id text;

-- Light shape checks (null = not set). A package/bundle is reverse-DNS; a Team
-- ID is 10 upper-alnum; fingerprints are one or more AA:BB:…:ZZ (32 upper-hex
-- octets) joined by commas, stored normalised by the settings action.
alter table studios
  add constraint studios_android_package_shape
    check (android_package is null
           or android_package ~ '^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$'),
  add constraint studios_ios_bundle_shape
    check (ios_bundle_id is null
           or ios_bundle_id ~ '^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$'),
  add constraint studios_ios_team_shape
    check (ios_team_id is null or ios_team_id ~ '^[A-Z0-9]{10}$'),
  add constraint studios_android_fingerprints_shape
    check (android_sha256_fingerprints is null
           or android_sha256_fingerprints ~
              '^([0-9A-F]{2}:){31}[0-9A-F]{2}(,([0-9A-F]{2}:){31}[0-9A-F]{2})*$');

-- -----------------------------------------------------------------------------
-- Re-issue studio_by_slug — add the four store columns. DROP+recreate (a
-- returns-table column change), so the anon/authenticated/service grants are
-- re-asserted; it stays the SAME anon function (thirteen total). Byte-for-byte
-- the 20260832130000 body + the four columns.
-- -----------------------------------------------------------------------------
drop function if exists studio_by_slug(text);
create function studio_by_slug(p_slug text)
 returns table(id uuid, name text, slug text, timezone text, currency text, logo_url text,
   theme_preset theme_preset, accent_color text, login_image_url text,
   login_image_focus_x smallint, login_image_focus_y smallint,
   free_first_class_enabled boolean, login_tagline text, install_welcome text, time_format text,
   android_package text, android_sha256_fingerprints text, ios_team_id text, ios_bundle_id text)
 language sql stable security definer set search_path to 'public' as $function$
  select s.id, s.name, s.slug, s.timezone, s.currency,
         s.logo_url, s.theme_preset, s.accent_color, s.login_image_url,
         s.login_image_focus_x, s.login_image_focus_y,
         coalesce(ss.free_first_class_enabled, false),
         s.login_tagline, s.install_welcome,
         coalesce(ss.time_format, '24h'),
         s.android_package, s.android_sha256_fingerprints, s.ios_team_id, s.ios_bundle_id
    from studios s
    left join studio_settings ss on ss.studio_id = s.id
   where s.slug = p_slug and s.status = 'active'
$function$;
revoke execute on function studio_by_slug(text) from public;
grant  execute on function studio_by_slug(text) to anon, authenticated, service_role;
