-- creates: post_edit_run_allowed(uuid)
-- re-issues: brand_kit_valid(jsonb)
--
-- Decision 93 slice 3 — edit the post with Claude (no Meta — part b).
--
-- A studio tells Claude what to change about a timetable post ("make it darker",
-- "use this photo behind the classes", "bigger times") and Claude returns an
-- updated spec in the SAME shape our renderer draws — it fills the spec, never an
-- image. Edits are capped at sixty a month per studio (post_edit_run_allowed,
-- desk-up, reason post_edit_limit — front desk edits posts too, matching the
-- desk-up Schedule-posts screen). The brand spec gains OPTIONAL per-post layout
-- fields (a background image reference, its placement + overlay, text alignment,
-- per-element size scales, element order); all optional, so an existing slice-1/2
-- kit validates unchanged.
--
-- SHAPE NOTE: the record speaks of "a spec plus layout"; we keep ONE object (the
-- brand spec, now carrying the optional layout fields) and ONE validator, so
-- "Save as my style" and "Just this post" share the shape and there is no second
-- definition to drift. The counter columns are written only by this RPC (SQL),
-- like brand_kit_runs_month / invoice_next_no, so they are not app-written
-- settings and need no registry field.
--
-- None anon; anon stays THIRTEEN.

-- --- Settings counter (SQL-written only) ------------------------------------
alter table studio_settings
  add column if not exists post_edit_runs_month int not null default 0 check (post_edit_runs_month >= 0),
  add column if not exists post_edit_runs_reset_on date;

-- --- The run gate (desk-up, sixty a month) ----------------------------------
create or replace function post_edit_run_allowed(p_studio_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_today date; v_used int; v_reset date; v_cap int := 60;
begin
  if not coalesce(is_desk_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only the studio team can edit posts' using errcode = 'PT403';
  end if;
  select (now() at time zone coalesce(timezone, 'UTC'))::date into v_today from studios where id = p_studio_id;
  select post_edit_runs_month, post_edit_runs_reset_on into v_used, v_reset
    from studio_settings where studio_id = p_studio_id for update;
  if v_reset is null or v_today >= v_reset then
    v_used := 0;
    v_reset := (date_trunc('month', v_today) + interval '1 month')::date;
  end if;
  if coalesce(v_used, 0) >= v_cap then
    update studio_settings set post_edit_runs_month = v_used, post_edit_runs_reset_on = v_reset
      where studio_id = p_studio_id;
    return jsonb_build_object('ok', false, 'reason', 'post_edit_limit', 'used', v_used, 'cap', v_cap);
  end if;
  v_used := v_used + 1;
  update studio_settings set post_edit_runs_month = v_used, post_edit_runs_reset_on = v_reset
    where studio_id = p_studio_id;
  return jsonb_build_object('ok', true, 'used', v_used, 'cap', v_cap);
end $$;
revoke execute on function post_edit_run_allowed(uuid) from public, anon;
grant  execute on function post_edit_run_allowed(uuid) to authenticated, service_role;

-- --- Extend the brand spec validator ----------------------------------------
-- Re-issued with the optional per-post layout fields. Each is valid ONLY in
-- range when present; absent is always valid (a slice-1/2 kit passes unchanged).
-- Mirrors lib/brand-kit.mjs isValidSpec.
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

-- --- Photos for the edit box go to post-images ------------------------------
-- Slice 2 made post-images png-only (for exported PNGs); an uploaded background
-- photo is usually a jpg or webp, so widen the bucket (the desk-up policies and
-- the 5 MB cap are unchanged).
update storage.buckets
   set allowed_mime_types = array['image/png','image/jpeg','image/webp']
 where id = 'post-images';

-- --- anon stays THIRTEEN -----------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % not 13', n; end if;
end $$;
