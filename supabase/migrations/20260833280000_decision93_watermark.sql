-- Decision 93 amendment — watermark_opacity.
-- re-issues: brand_kit_valid(jsonb)
--
-- A faint kit-logo watermark is a new OPTIONAL spec field (0..0.4). The TS
-- validator (lib/brand-kit.mjs isValidSpec) already enforces the bound and
-- parseBrandSpec clamps it; the saved kit's spec is validated in SQL by
-- brand_kit_valid (called from brand_kit_save), so re-issue it to carry the same
-- bound and keep the SQL mirror exact. Absent is always valid (every existing
-- kit passes unchanged). No new column, no new anon surface.

create or replace function brand_kit_valid(p_spec jsonb)
returns boolean language sql immutable set search_path = public as $$
  select coalesce(
    (select bool_and(coalesce(p_spec->'colors'->>k, '') ~ '^#[0-9A-Fa-f]{6}$')
       from unnest(array['background','surface','ink','accent','secondary']) k)
    and (p_spec->>'display_font') = any (array[
          'Instrument Serif','Bodoni Moda','Playfair Display','Manrope','Space Grotesk',
          'Inter','Space Mono','DM Sans','Fraunces','Cormorant'])
    and (p_spec->>'body_font') = any (array[
          'Instrument Serif','Bodoni Moda','Playfair Display','Manrope','Space Grotesk',
          'Inter','Space Mono','DM Sans','Fraunces','Cormorant'])
    and (p_spec->>'layout') = any (array['list','grid','poster'])
    and (p_spec->>'radius') = any (array['small','large'])
    and (p_spec->>'logo_placement') = any (array['top-left','top-centre','bottom'])
    and (p_spec->>'background_treatment') = any (array['none','soft','full'])
    and coalesce(length(p_spec->>'tone'), 0) <= 200
    -- optional layout fields
    and (p_spec->'background_image' is null or jsonb_typeof(p_spec->'background_image') = 'string')
    and (p_spec->'image_placement'  is null or (p_spec->>'image_placement') = any (array['top','left','right','full']))
    and (p_spec->'text_align'       is null or (p_spec->>'text_align')      = any (array['left','center','right']))
    and (p_spec->'overlay_strength' is null or (
          jsonb_typeof(p_spec->'overlay_strength') = 'number'
          and (p_spec->>'overlay_strength')::numeric between 0 and 1))
    and (p_spec->'watermark_opacity' is null or (
          jsonb_typeof(p_spec->'watermark_opacity') = 'number'
          and (p_spec->>'watermark_opacity')::numeric between 0 and 0.4))
    and (p_spec->'element_order' is null or (
          jsonb_typeof(p_spec->'element_order') = 'array'
          and not exists (select 1 from jsonb_array_elements_text(p_spec->'element_order') t
                          where t not in ('logo','title','classes','footer'))))
    and (p_spec->'size_scale' is null or (
          jsonb_typeof(p_spec->'size_scale') = 'object'
          and not exists (select 1 from (values ('time'),('name'),('header')) v(k)
                          where p_spec->'size_scale'->(v.k) is not null
                            and (jsonb_typeof(p_spec->'size_scale'->(v.k)) <> 'number'
                                 or (p_spec->'size_scale'->>(v.k))::numeric not between 0.5 and 2)))),
  false);
$$;
revoke execute on function brand_kit_valid(jsonb) from public, anon;
grant  execute on function brand_kit_valid(jsonb) to authenticated, service_role;

-- --- anon stays THIRTEEN -----------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % not 13', n; end if;
end $$;
