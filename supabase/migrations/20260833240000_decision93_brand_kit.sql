-- creates: brand_kit_valid(jsonb), brand_kit_defaults(uuid), brand_kit_current(uuid), brand_kit_save(uuid, jsonb, text), brand_kit_run_allowed(uuid)
--
-- Decision 93 slice 1 — the brand kit only (no posts screen, no editing, no Meta).
--
-- A studio learns its look from up to five reference designs (private bucket
-- brand-references) and stores a brand spec in studio_brand_kits (one CURRENT
-- kit per studio, history kept). The spec is drawn by our renderer; Claude only
-- fills the spec (slice 1 learns it; the learn RPC gate is brand_kit_run_allowed,
-- ten per studio per month). A studio with no kit uses defaults built from its
-- accent + theme preset, Space Grotesk, list layout.
--
-- SIGNATURE NOTE: the decision wrote brand_kit_save(spec, source) /
-- brand_kit_run_allowed() tersely; these are studio-scoped multi-tenant writers
-- and a manager may be staff of more than one studio, so they take p_studio_id
-- first (as brand_kit_current(studio) already does) rather than guessing the
-- caller's studio. brand_kit_current returns a SUPERSET — spec + source +
-- defaults + the month's run count — so the Brand kit page reads it all in one
-- desk-up call.
--
-- Spec shape (validated by brand_kit_valid, mirrored in lib/brand-kit.mjs):
--   { colors: { background, surface, ink, accent, secondary }  (6-hex each),
--     display_font, body_font   (from the vendored 10-font list),
--     layout: list|grid|poster, radius: small|large, tone: <=200 chars,
--     logo_placement: top-left|top-centre|bottom,
--     background_treatment: none|soft|full }
--
-- None anon; anon stays THIRTEEN.

-- ---------------------------------------------------------------- table
create table studio_brand_kits (
  id         uuid primary key default gen_random_uuid(),
  studio_id  uuid not null references studios(id) on delete cascade,
  spec       jsonb not null,
  source     text  not null check (source in ('default', 'learned', 'manual')),
  is_current boolean not null default true,
  created_by uuid,
  created_at timestamptz not null default now()
);
-- one current kit per studio
create unique index brand_kits_one_current on studio_brand_kits (studio_id) where is_current;
create index brand_kits_studio on studio_brand_kits (studio_id, created_at desc);

alter table studio_brand_kits enable row level security;
-- desk-up read (front desk sees the kit read-only); writes only via the definer RPC.
create policy brand_kits_desk_read on studio_brand_kits for select to authenticated
  using (coalesce(is_desk_up(studio_id), false));
grant select on studio_brand_kits to authenticated;
grant all on studio_brand_kits to service_role;

-- ---------------------------------------------------------------- settings columns
alter table studio_settings add column brand_kit_runs_month int not null default 0 check (brand_kit_runs_month >= 0);
alter table studio_settings add column brand_kit_runs_reset_on date;

-- ---------------------------------------------------------------- bucket + policies
-- private; 10 MB; png/jpg/pdf; path {studio_id}/{file}; manager-up read+write
-- (the message-attachments shape, Decision 89, with is_manager_up).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('brand-references', 'brand-references', false, 10485760,
        array['image/png', 'image/jpeg', 'image/jpg', 'application/pdf'])
on conflict (id) do nothing;

create policy brand_ref_write on storage.objects for insert to authenticated
  with check (bucket_id = 'brand-references'
    and coalesce(is_manager_up(((storage.foldername(name))[1])::uuid), false));
create policy brand_ref_update on storage.objects for update to authenticated
  using (bucket_id = 'brand-references'
    and coalesce(is_manager_up(((storage.foldername(name))[1])::uuid), false));
create policy brand_ref_delete on storage.objects for delete to authenticated
  using (bucket_id = 'brand-references'
    and coalesce(is_manager_up(((storage.foldername(name))[1])::uuid), false));
create policy brand_ref_read on storage.objects for select to authenticated
  using (bucket_id = 'brand-references'
    and coalesce(is_manager_up(((storage.foldername(name))[1])::uuid), false));

-- ---------------------------------------------------------------- validation
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
    and coalesce(length(p_spec->>'tone'), 0) <= 200,
  false);
$$;
revoke execute on function brand_kit_valid(jsonb) from public, anon;
grant  execute on function brand_kit_valid(jsonb) to authenticated, service_role;

-- ---------------------------------------------------------------- defaults
-- Built from the studio's accent + theme preset (the lib/theme.ts tokens),
-- Space Grotesk, list layout. Desk-up (the Brand kit page reads it for reset).
create or replace function brand_kit_defaults(p_studio_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s studios%rowtype; v_surface text; v_paper text; v_ink text; v_ink2 text;
begin
  if not coalesce(is_desk_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only staff read the brand kit' using errcode = 'PT403';
  end if;
  select * into s from studios where id = p_studio_id;
  -- theme preset tokens, mirroring lib/theme.ts PRESETS
  case s.theme_preset
    when 'clean' then v_surface := '#FFFFFF'; v_paper := '#FFFFFF'; v_ink := '#0A0A0A'; v_ink2 := '#404040';
    when 'calm'  then v_surface := '#FBFCFB'; v_paper := '#F2F5F2'; v_ink := '#1A211A'; v_ink2 := '#4A554A';
    when 'bold'  then v_surface := '#16181A'; v_paper := '#0E1012'; v_ink := '#F5F5F4'; v_ink2 := '#C4C4C2';
    else              v_surface := '#FFFFFF'; v_paper := '#FAFAF7'; v_ink := '#14170E'; v_ink2 := '#57534E';
  end case;
  return jsonb_build_object(
    'colors', jsonb_build_object(
      'background', v_paper, 'surface', v_surface, 'ink', v_ink,
      'accent', coalesce(nullif(s.accent_color, ''), '#78716C'),
      'secondary', v_ink2),
    'display_font', 'Space Grotesk', 'body_font', 'Space Grotesk',
    'layout', 'list', 'radius', 'small',
    'tone', 'Clean, calm and legible.',
    'logo_placement', 'top-left', 'background_treatment', 'none');
end $$;
revoke execute on function brand_kit_defaults(uuid) from public, anon;
grant  execute on function brand_kit_defaults(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------- current (read)
-- Returns the current spec (or the defaults), the source, the defaults (for the
-- reset button) and the month's run count — one desk-up read for the page.
create or replace function brand_kit_current(p_studio_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare k studio_brand_kits%rowtype; v_def jsonb; v_today date; v_used int; v_reset date;
begin
  if not coalesce(is_desk_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only staff read the brand kit' using errcode = 'PT403';
  end if;
  v_def := brand_kit_defaults(p_studio_id);
  select * into k from studio_brand_kits where studio_id = p_studio_id and is_current;
  select (now() at time zone coalesce(timezone, 'UTC'))::date into v_today from studios where id = p_studio_id;
  select brand_kit_runs_month, brand_kit_runs_reset_on into v_used, v_reset
    from studio_settings where studio_id = p_studio_id;
  if v_reset is null or v_today >= v_reset then v_used := 0; end if;
  return jsonb_build_object(
    'spec',      coalesce(k.spec, v_def),
    'source',    coalesce(k.source, 'default'),
    'defaults',  v_def,
    'runs_used', coalesce(v_used, 0),
    'runs_cap',  10);
end $$;
revoke execute on function brand_kit_current(uuid) from public, anon;
grant  execute on function brand_kit_current(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------- save (write)
create or replace function brand_kit_save(p_studio_id uuid, p_spec jsonb, p_source text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers manage the brand kit' using errcode = 'PT403';
  end if;
  if p_source is null or p_source not in ('default', 'learned', 'manual') then
    raise exception 'unknown brand kit source' using errcode = 'PT400';
  end if;
  if not brand_kit_valid(p_spec) then
    raise exception 'invalid brand spec' using errcode = 'PT400';
  end if;
  update studio_brand_kits set is_current = false where studio_id = p_studio_id and is_current;
  insert into studio_brand_kits (studio_id, spec, source, is_current, created_by)
    values (p_studio_id, p_spec, p_source, true, auth.uid())
    returning id into v_id;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (p_studio_id, auth.uid(), 'brand_kit.saved', 'studio_brand_kits', v_id,
            jsonb_build_object('source', p_source, 'spec', p_spec));
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;
revoke execute on function brand_kit_save(uuid, jsonb, text) from public, anon;
grant  execute on function brand_kit_save(uuid, jsonb, text) to authenticated, service_role;

-- ---------------------------------------------------------------- run gate
-- Increments the month's run counter and refuses past ten (reason brand_kit_limit).
-- The counter resets on the first of the studio-local month.
create or replace function brand_kit_run_allowed(p_studio_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_today date; v_used int; v_reset date; v_cap int := 10;
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers manage the brand kit' using errcode = 'PT403';
  end if;
  select (now() at time zone coalesce(timezone, 'UTC'))::date into v_today from studios where id = p_studio_id;
  select brand_kit_runs_month, brand_kit_runs_reset_on into v_used, v_reset
    from studio_settings where studio_id = p_studio_id for update;
  if v_reset is null or v_today >= v_reset then
    v_used := 0;
    v_reset := (date_trunc('month', v_today) + interval '1 month')::date;
  end if;
  if coalesce(v_used, 0) >= v_cap then
    update studio_settings set brand_kit_runs_month = v_used, brand_kit_runs_reset_on = v_reset
      where studio_id = p_studio_id;
    return jsonb_build_object('ok', false, 'reason', 'brand_kit_limit', 'used', v_used, 'cap', v_cap);
  end if;
  v_used := v_used + 1;
  update studio_settings set brand_kit_runs_month = v_used, brand_kit_runs_reset_on = v_reset
    where studio_id = p_studio_id;
  return jsonb_build_object('ok', true, 'used', v_used, 'cap', v_cap);
end $$;
revoke execute on function brand_kit_run_allowed(uuid) from public, anon;
grant  execute on function brand_kit_run_allowed(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------- anon stays THIRTEEN
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % not 13', n; end if;
end $$;
