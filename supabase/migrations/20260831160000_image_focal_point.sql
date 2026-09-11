-- =============================================================================
-- 111 — a studio says what matters in its photograph, so the crop keeps it.
--
-- MEASURED BEFORE ANYTHING WAS CHANGED. A 1600×600 photograph on a 375×812
-- phone, through `object-fit: cover`: the image is scaled to fill the height
-- (812/600 = 1.35×), which makes it 2165px wide, and 375 of those survive.
-- **SEVENTEEN PER CENT OF THE PICTURE, DEAD CENTRE.** With an eight-column test
-- image the login screen kept columns 4 and 5 and nothing else; a subject at 22%
-- of the frame was not on screen at all.
--
-- `contain` is not the fix — it leaves empty bands above and below on a portrait
-- screen, which looks worse than a crop. The fix is to crop around something
-- other than the geometric middle, because a studio's shot of its reformers
-- rarely has them in the centre of the frame.
--
-- TWO SMALLINTS RATHER THAN ONE TEXT COLUMN. The value ends up in an inline
-- `object-position`, and a text column would be a string from the database
-- landing in a style attribute. Ints bounded 0–100 by a CHECK cannot carry
-- anything but a percentage, and the CSS is composed in code from them.
--
-- Defaults are 50/50, which is exactly what `cover` does today — so every
-- existing studio and every existing class type renders byte-identically until
-- somebody moves the point.
-- =============================================================================

alter table studios
  add column if not exists login_image_focus_x smallint not null default 50,
  add column if not exists login_image_focus_y smallint not null default 50;

alter table class_types
  add column if not exists image_focus_x smallint not null default 50,
  add column if not exists image_focus_y smallint not null default 50;

comment on column studios.login_image_focus_x is
  'Per cent across the login photograph that must survive the crop. 50 is the geometric centre, which is what object-fit: cover does on its own.';
comment on column class_types.image_focus_x is
  'Per cent across the class photograph that must survive the crop, for the member app''s hero and coming-up cards.';

alter table studios drop constraint if exists studio_login_focus_in_range;
alter table studios add constraint studio_login_focus_in_range check (
  login_image_focus_x between 0 and 100 and login_image_focus_y between 0 and 100);

alter table class_types drop constraint if exists class_type_focus_in_range;
alter table class_types add constraint class_type_focus_in_range check (
  image_focus_x between 0 and 100 and image_focus_y between 0 and 100);

-- -----------------------------------------------------------------------------
-- The pre-login lookup has to carry it, because the login screen is the worst
-- case and it renders before anybody has signed in.
--
-- A `RETURNS TABLE` cannot gain a column through `create or replace`, so this
-- drops first — and a drop discards the ACL. This is ONE OF THE NINE PRE-LOGIN
-- SURFACES, so it is the one function in the codebase where losing a grant means
-- the login screen stops working for everybody, and where regaining it wrongly
-- means handing `anon` something new. Re-granted below to exactly the three
-- roles it had, and then asserted.
-- -----------------------------------------------------------------------------
drop function if exists studio_by_slug(text);
create function studio_by_slug(p_slug text)
returns table (
  id uuid, name text, slug text, timezone text, currency text,
  logo_url text, theme_preset theme_preset, accent_color text, login_image_url text,
  login_image_focus_x smallint, login_image_focus_y smallint
)
language sql stable security definer set search_path = public as $$
  select s.id, s.name, s.slug, s.timezone, s.currency,
         s.logo_url, s.theme_preset, s.accent_color, s.login_image_url,
         s.login_image_focus_x, s.login_image_focus_y
    from studios s
   where s.slug = p_slug and s.status = 'active'
$$;

revoke execute on function studio_by_slug(text) from public;
grant execute on function studio_by_slug(text) to anon, authenticated, service_role;

do $$
declare v_oid oid := 'studio_by_slug(text)'::regprocedure;
begin
  -- It MUST be anon-callable: it is the pre-login lookup, and the member app's
  -- login screen cannot render without it.
  if not has_function_privilege('anon', v_oid, 'execute') then
    raise exception 'migration 111: studio_by_slug lost the anon grant the login screen needs';
  end if;
  if not has_function_privilege('authenticated', v_oid, 'execute') then
    raise exception 'migration 111: studio_by_slug lost the authenticated grant';
  end if;
  -- And the anon surface must still be the same nine names — a drop and recreate
  -- is exactly how a tenth would arrive without anybody noticing.
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and has_function_privilege('anon', p.oid, 'execute')
         and p.proname not like 'expect%' and p.proname not in ('login','sig','psig')) <> 9
  then
    raise exception 'migration 111: the anon surface is no longer exactly nine';
  end if;
end $$;
