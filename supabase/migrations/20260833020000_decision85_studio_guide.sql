-- Decision 85 — Studio Guide (instructor, 85a). The two per-person "seen" flags
-- the portal reads, and the one writer that sets them.
-- creates: instructor_guide_mark(text)
-- re-issues: my_instructor()
--
-- The guide text itself lives in lib/instructor-guide.mjs (verbatim, platform-
-- wide, {studio_name} the only token). The DATABASE carries only whether this
-- person has seen the five-card intro and which one-line hints they have
-- dismissed — nothing studio-specific, so these are NOT studio_settings and get
-- no registry entry. The member guide (85b) is why the same two columns go on
-- members now, unused until then.

alter table instructors
  add column if not exists guide_seen_at timestamptz,
  add column if not exists hints_seen    jsonb not null default '{}'::jsonb;

alter table members
  add column if not exists guide_seen_at timestamptz,
  add column if not exists hints_seen    jsonb not null default '{}'::jsonb;

-- The one writer. SECURITY DEFINER so it sets the flag for the signed-in
-- instructor without an instructors write policy; it resolves auth.uid() ->
-- studio_staff -> instructors itself and touches ONLY rows that login owns, so
-- it can never write somebody else's. 'intro' marks the five-card intro seen,
-- 'reset' un-marks it (Show the intro again), any other value records a
-- dismissed hint. A caller who is not an instructor is refused (0 rows updated).
-- It never touches a demo instructor — those carry no staff_id, so no row ever
-- matches — so the demo-promote trigger is not a concern here.
create function instructor_guide_mark(p_hint text) returns void
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if p_hint = 'intro' then
    update instructors i set guide_seen_at = now()
     where i.staff_id in (select id from studio_staff where user_id = auth.uid() and status = 'active')
       and i.status = 'active';
  elsif p_hint = 'reset' then
    update instructors i set guide_seen_at = null
     where i.staff_id in (select id from studio_staff where user_id = auth.uid() and status = 'active')
       and i.status = 'active';
  else
    update instructors i
       set hints_seen = coalesce(i.hints_seen, '{}'::jsonb) || jsonb_build_object(p_hint, true)
     where i.staff_id in (select id from studio_staff where user_id = auth.uid() and status = 'active')
       and i.status = 'active';
  end if;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'that is not your instructor account' using errcode = 'PT403';
  end if;
end $$;

revoke execute on function instructor_guide_mark(text) from public, anon;
grant  execute on function instructor_guide_mark(text) to authenticated, service_role;

-- my_instructor re-issued VERBATIM from 20260832900000 (Decision 82) with two
-- additive fields: guide_seen_at (the intro flag) and hints_seen (the dismissed
-- one-line hints). create-or-replace keeps the ACL and the anon surface; nothing
-- else changes.
create or replace function my_instructor()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r record;
begin
  select i.id as instructor_id, i.display_name, i.avatar_url, i.bio,
         s.id as studio_id, s.name as studio_name, s.slug, s.timezone, s.currency,
         s.accent_color, s.theme_preset, s.logo_url, ss.email, ss.role,
         coalesce(st.week_starts_on, 1) as week_starts_on,
         coalesce(st.time_format, '24h') as time_format,
         (coalesce(st.guarantees_enabled, false) or coalesce(st.flex_enabled, false)) as uses_payroll,
         (select count(*) from notifications n
           where n.user_id = ss.user_id and n.studio_id = s.id
             and n.channel = 'email' and n.status <> 'failed' and n.read_at is null) as unread,
         -- Decision 85: the per-person guide flags the portal reads.
         i.guide_seen_at,
         coalesce(i.hints_seen, '{}'::jsonb) as hints_seen
    into r
    from studio_staff ss
    join instructors i on i.staff_id = ss.id
    join studios s on s.id = ss.studio_id
    left join studio_settings st on st.studio_id = s.id
   where ss.user_id = auth.uid() and ss.status = 'active' and i.status = 'active'
   order by ss.created_at limit 1;
  if r.instructor_id is null then return null; end if;
  return to_jsonb(r);
end $$;

-- Anon surface stays EXACTLY THIRTEEN (this migration adds one authenticated-
-- only function and re-issues one SECURITY DEFINER reader; neither is anon).
do $$
declare n int;
begin
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect_%'
     and p.proname not in ('login','sig','psig');
  if n <> 13 then
    raise exception 'anon surface is % functions, expected exactly 13', n;
  end if;
end $$;
