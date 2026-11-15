-- UI pool: Decision 22(c) public timetable tier, Decision 105 members list, and
-- the Decision 103(b) credit-back email copy fix.
--
-- creates: members_list(uuid, text, text, text, integer)
-- re-issues: public_schedule(text, integer)
--
-- public_schedule carries the effective tier per class and whether the studio
-- runs guarantees (22c); a member/instructor SELECT policy on class_series lets
-- the member Book embed of class_series(tier) resolve so the tier never depends
-- on staff visibility (22c); members_list is the one staff-only reader for the
-- search/filter/sort Members list (105); and the free_reservation_credited
-- default body is re-issued to the agreed copy. No new anon RPC: public_schedule
-- keeps its anon grant and stays one of the THIRTEEN; members_list is desk-up.

-- ============================================================================
-- Decision 22(c): public_schedule re-issued (+ tier per class, + guarantees_enabled)
-- Re-issued byte-faithfully from migration 20260833190000 with three additions:
-- a left join to class_series, the effective-tier column, and guarantees_enabled.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.public_schedule(p_slug text, p_days integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_studio   studios%rowtype;
  v_tz       text;
  v_window   int;
  v_days     int;
  v_from     timestamptz;
  v_to       timestamptz;
  v_cached   jsonb;
  v_payload  jsonb;
  v_classes  jsonb;
  v_state    text;
  v_next_pub timestamptz;
  v_next_any timestamptz;
  v_next_from text;
  v_limit    int := 40;   -- the fallback's "next N classes" cap (bounded for anon)
  v_name_mode text;
  v_fmt text;
  v_guar boolean;         -- 22c: does the studio run guarantees (drives the embed tint)
begin
  select * into v_studio from studios where slug = lower(p_slug) and status = 'active';
  if not found then
    return jsonb_build_object('found', false);
  end if;
  v_tz := v_studio.timezone;

  select coalesce(booking_window_days, 30) into v_window
    from studio_settings where studio_id = v_studio.id;
  v_window := coalesce(v_window, 30);
  select coalesce(public_instructor_name, 'first') into v_name_mode
    from studio_settings where studio_id = v_studio.id;
  v_name_mode := coalesce(v_name_mode, 'first');
  select coalesce(time_format, '24h') into v_fmt
    from studio_settings where studio_id = v_studio.id;
  v_fmt := coalesce(v_fmt, '24h');
  select coalesce(guarantees_enabled, false) into v_guar
    from studio_settings where studio_id = v_studio.id;
  v_guar := coalesce(v_guar, false);
  v_days := least(greatest(coalesce(p_days, v_window), 1), v_window);

  select payload into v_cached
    from public_schedule_cache
   where slug = v_studio.slug and days = v_days
     and computed_at > now() - interval '5 minutes';
  if v_cached is not null then
    return v_cached;
  end if;

  v_from := (date_trunc('day', now() at time zone v_tz)) at time zone v_tz;
  v_to   := (date_trunc('day', now() at time zone v_tz) + make_interval(days => v_days)) at time zone v_tz;

  if exists (
    select 1 from class_occurrences o
     where o.studio_id = v_studio.id and o.status = 'scheduled' and not o.hidden_from_members
       and o.starts_at >= v_from and o.starts_at < v_to
       and month_published(v_studio.id, o.starts_at)
       and (o.staffing = 'assigned' or not studio_hides_unstaffed(v_studio.id))
  ) then
    v_state := 'in_window';
  else
    select min(o.starts_at) into v_next_pub
      from class_occurrences o
     where o.studio_id = v_studio.id and o.status = 'scheduled' and not o.hidden_from_members
       and o.starts_at >= v_to
       and month_published(v_studio.id, o.starts_at)
       and (o.staffing = 'assigned' or not studio_hides_unstaffed(v_studio.id));
    if v_next_pub is not null then
      v_state    := 'upcoming';
      v_next_from := to_char(v_next_pub at time zone v_tz, 'YYYY-MM-DD');
    else
      select min(o.starts_at) into v_next_any
        from class_occurrences o
       where o.studio_id = v_studio.id and o.status = 'scheduled' and not o.hidden_from_members
         and o.starts_at >= v_from;
      if v_next_any is not null then
        v_state    := 'unpublished';
        v_next_from := to_char(v_next_any at time zone v_tz, 'YYYY-MM-DD');
      else
        v_state := 'empty';
      end if;
    end if;
  end if;

  if v_state in ('in_window', 'upcoming') then
    select coalesce(jsonb_agg(c order by c.starts_at), '[]'::jsonb) into v_classes
    from (
      select
        o.id,
        to_char(o.starts_at at time zone v_tz, 'YYYY-MM-DD')            as date,
        to_char(o.starts_at at time zone v_tz, 'HH24:MI')              as time,
        o.starts_at,
        ct.duration_minutes,
        ct.name                                                        as class_name,
        ct.description,
        ct.color,
        -- Decision 22(c): the effective tier, resolved the same way the member
        -- Book tab and occurrence_guarantee_run do (occurrence first, then the
        -- series, then core). The embed draws core and always with the tint and
        -- the "Always runs" chip; flex is plain.
        case when not v_guar then null
          else case
            when o.guarantee_tier is not null then o.guarantee_tier::text
            when o.flex then 'flex'
            when cs.guarantee_tier is not null then cs.guarantee_tier::text
            when cs.flex then 'flex'
            else 'core'
          end
        end                                                            as tier,
        case when o.instructor_id is null then null
             when v_name_mode = 'full' then i.display_name
             else split_part(i.display_name, ' ', 1) end              as instructor_first_name,
        i.avatar_url                                                   as instructor_avatar_url,
        r.name                                                         as room,
        o.capacity,
        greatest(o.capacity - o.booked_count, 0)                       as spaces_left,
        (o.booked_count >= o.capacity)                                 as full,
        'https://' || v_studio.slug || '.studiior.app/class/' || o.id  as book_url
      from class_occurrences o
      join class_types ct on ct.id = o.class_type_id
      left join class_series cs on cs.id = o.series_id
      left join instructors i on i.id = o.instructor_id
      left join rooms r on r.id = o.room_id
      where o.studio_id = v_studio.id
        and o.status = 'scheduled' and not o.hidden_from_members
        and o.starts_at >= v_from
        and (v_state = 'upcoming' or o.starts_at < v_to)
        and month_published(v_studio.id, o.starts_at)
        and (o.staffing = 'assigned' or not studio_hides_unstaffed(v_studio.id))
      order by o.starts_at
      limit case when v_state = 'upcoming' then v_limit else null end
    ) c;
  else
    v_classes := '[]'::jsonb;
  end if;

  v_payload := jsonb_build_object(
    'found', true,
    'state', v_state,
    'next_from', v_next_from,
    'window_days', v_days,
    'generated_at', now(),
    'studio', jsonb_build_object(
      'name',               v_studio.name,
      'slug',               v_studio.slug,
      'timezone',           v_tz,
      'accent_color',       v_studio.accent_color,
      'theme_preset',       v_studio.theme_preset,
      'logo_url',           v_studio.logo_url,
      'app_origin',         'https://' || v_studio.slug || '.studiior.app',
      'time_format',        v_fmt,
      'guarantees_enabled', v_guar
    ),
    'classes', v_classes
  );

  insert into public_schedule_cache (slug, days, payload, computed_at)
  values (v_studio.slug, v_days, v_payload, now())
  on conflict (slug, days) do update
    set payload = excluded.payload, computed_at = excluded.computed_at;

  return v_payload;
end $function$;
-- public_schedule keeps its anon grant (create-or-replace), still one of THIRTEEN.

-- ============================================================================
-- Decision 22(c): a member/instructor SELECT policy on class_series.
-- Instructors with a login are studio staff, so series_staff_read already covers
-- them; only pure members lack a read today (a member reads zero class_series
-- rows, so the Book embed of class_series(guarantee_tier, flex) comes back null).
-- class_series is the public timetable TEMPLATE (name, rrule, times, capacity,
-- tier flags) and carries no member-private data, so exposing it to a member of
-- the studio is safe and is what the embed needs.
-- ============================================================================
drop policy if exists class_series_member_read on class_series;
create policy class_series_member_read on class_series
  for select to authenticated
  using (
    studio_id in (
      select m.studio_id from members m
       where m.user_id = auth.uid() and m.deleted_at is null
    )
  );

-- ============================================================================
-- Decision 105: members_list — the one staff-only reader for the Members list.
-- Reuses member_plan_overview (role-guarded, so no subject-identity caller flag)
-- for every base field, and adds the phone, a possible-duplicate flag (set-based
-- on the immutable normalise helpers), an unpaid-reservation-fee-due flag (the
-- studio-wide form of the sweep_free_reservation_dues predicate), and a
-- waiver-missing-with-a-future-booking flag. Returns the filtered/searched/sorted
-- rows AND the chip counts (over the current search) in ONE call. Desk-up.
-- ============================================================================
drop function if exists members_list(uuid, text, text, text, integer);
create function members_list(
  p_studio_id uuid,
  p_search text default '',
  p_filter text default 'all',
  p_sort text default 'attention',
  p_page int default 1
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_country text;
  v_today date;
  v_tz text;
  v_q text := btrim(coalesce(p_search, ''));
  v_digits text := regexp_replace(coalesce(p_search, ''), '\D', '', 'g');
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_size int := 500;                 -- "paging stays as today": one page for a studio
  v_result jsonb;
begin
  if not (is_desk_up(p_studio_id) or is_service_context()) then
    raise exception 'that is another studio''s members' using errcode = 'PT403';
  end if;
  select timezone, country into v_tz, v_country from studios where id = p_studio_id;
  v_today := (now() at time zone v_tz)::date;

  with base as (
    select * from member_plan_overview(p_studio_id)
  ),
  ph as (
    select m.id, m.phone,
           normalise_name(coalesce(m.first_name,'') || ' ' || coalesce(m.last_name,'')) as nn,
           btrim(coalesce(m.last_name,'')) as ln,
           normalise_phone(m.phone, v_country) as np
      from members m
     where m.studio_id = p_studio_id and m.deleted_at is null
  ),
  dup_name as (                       -- a normalised name shared by >= 2 members with a non-empty last name
    select nn from ph where ln <> '' and nn is not null group by nn having count(*) > 1
  ),
  dup_phone as (                      -- a normalised phone shared by >= 2 members
    select np from ph where np is not null group by np having count(*) > 1
  ),
  dup as (
    select p.id,
           (exists (select 1 from dup_name d where d.nn = p.nn and p.ln <> '')
            or exists (select 1 from dup_phone d where d.np = p.np)) as has_duplicate
      from ph p
  ),
  fee_due as (                        -- the studio-wide form of the reservation-dues predicate
    select distinct b.member_id
      from bookings b
      join class_occurrences o on o.id = b.occurrence_id
      join studio_settings st on st.studio_id = b.studio_id
      join members mb on mb.id = b.member_id
     where b.studio_id = p_studio_id
       and b.status = 'booked' and b.payment_source = 'comp'
       and mb.reservation_fee_waived_at is null and not b.reservation_fee_waived
       and st.free_first_reservation_from is not null
       and coalesce(st.free_first_reservation_fee_cents, 0) > 0
       and o.starts_at - make_interval(mins => coalesce(st.cancellation_cutoff_minutes, 0)) > now()
       and exists (select 1 from guest_passes gp where gp.guest_booking_id = b.id and gp.host_member_id is null)
       and not exists (select 1 from payments p where p.booking_id = b.id and p.kind = 'reservation_fee'
                        and p.status in ('succeeded','partially_refunded'))
  ),
  needs_waiver as (                   -- waiver required + a version exists + unsigned/needs-resign + a booking ahead
    select m.id
      from members m
     where m.studio_id = p_studio_id and m.deleted_at is null
       and coalesce((select require_waiver from studio_settings where studio_id = p_studio_id), false)
       and exists (select 1 from waiver_versions wv where wv.studio_id = p_studio_id)
       and (
         m.waiver_signed_at is null
         or exists (
           select 1 from waiver_versions wv
            where wv.studio_id = p_studio_id and wv.requires_resign
              and wv.created_at = (select max(created_at) from waiver_versions where studio_id = p_studio_id)
              and not exists (select 1 from waiver_signatures ws where ws.member_id = m.id and ws.version_id = wv.id))
       )
       and exists (select 1 from bookings b join class_occurrences o on o.id = b.occurrence_id
                    where b.member_id = m.id and b.status in ('booked','attended','pending_payment','waitlisted')
                      and o.starts_at > now())
  ),
  rows as (
    select base.id, base.first_name, base.last_name, base.email, ph.phone,
           base.status, base.lifetime_visits, base.last_visit_at, base.user_id,
           base.health_band, base.health_reason,
           base.current_plan_name, base.plan_type, base.expires_on, base.credits_remaining,
           base.plan_state, base.complimentary, base.free_stage, base.has_unpaid_booking,
           base.joined_on, base.reservation_fee_waived,
           coalesce(dup.has_duplicate, false) as has_duplicate,
           (fee_due.member_id is not null) as has_fee_due,
           (needs_waiver.id is not null) as needs_waiver,
           false as deleted
      from base
      left join ph on ph.id = base.id
      left join dup on dup.id = base.id
      left join fee_due on fee_due.member_id = base.id
      left join needs_waiver on needs_waiver.id = base.id
  ),
  del as (                            -- deleted members (for the Deleted chip only)
    select m.id, m.first_name, m.last_name, m.email, m.phone,
           'deleted'::text as status, 0 as lifetime_visits, null::timestamptz as last_visit_at,
           m.user_id, null::text as health_band, null::text as health_reason,
           null::text as current_plan_name, null::text as plan_type,
           null::date as expires_on, null::int as credits_remaining, 'none'::text as plan_state,
           false as complimentary, null::text as free_stage, false as has_unpaid_booking,
           m.joined_on, false as reservation_fee_waived, false as has_duplicate,
           false as has_fee_due, false as needs_waiver, true as deleted,
           m.deleted_at, m.merged_into
      from members m
     where m.studio_id = p_studio_id and m.deleted_at is not null
  ),
  -- search over the live rows
  searched as (
    select r.* from rows r
     where v_q = ''
        or (coalesce(r.first_name,'') || ' ' || coalesce(r.last_name,'')) ilike '%' || v_q || '%'
        or coalesce(r.email,'') ilike '%' || v_q || '%'
        or (length(v_digits) >= 4 and regexp_replace(coalesce(r.phone,''), '\D', '', 'g') like '%' || v_digits || '%')
  ),
  searched_del as (
    select d.* from del d
     where v_q = ''
        or (coalesce(d.first_name,'') || ' ' || coalesce(d.last_name,'')) ilike '%' || v_q || '%'
        or coalesce(d.email,'') ilike '%' || v_q || '%'
        or (length(v_digits) >= 4 and regexp_replace(coalesce(d.phone,''), '\D', '', 'g') like '%' || v_digits || '%')
  ),
  counts as (
    select jsonb_build_object(
      'all',           count(*),
      'active',        count(*) filter (where status = 'active'),
      'leads',         count(*) filter (where status = 'lead'),
      'unpaid',        count(*) filter (where has_unpaid_booking),
      'free_pending',  count(*) filter (where plan_state = 'free_only' and free_stage = 'booked'),
      'attention',     count(*) filter (where has_fee_due or has_duplicate or needs_waiver),
      'deleted',       (select count(*) from searched_del)
    ) as c from searched
  ),
  filtered as (
    select * from (
      select s.*, null::timestamptz as deleted_at, null::uuid as merged_into from searched s
       where case p_filter
               when 'active'       then status = 'active'
               when 'leads'        then status = 'lead'
               when 'unpaid'       then has_unpaid_booking
               when 'free_pending' then plan_state = 'free_only' and free_stage = 'booked'
               when 'attention'    then has_fee_due or has_duplicate or needs_waiver
               else true                       -- 'all' and anything else
             end
         and p_filter <> 'deleted'
      union all
      select sd.* from searched_del sd where p_filter = 'deleted'
    ) u
    order by
      case when p_sort = 'name' then lower(coalesce(u.first_name,'') || ' ' || coalesce(u.last_name,'')) end asc,
      case when p_sort = 'last_visit' then u.last_visit_at end desc nulls last,
      case when p_sort = 'joined' then u.joined_on end desc nulls last,
      -- default (attention): unpaid/fee/duplicate/waiver first, then recent visit
      case when p_sort not in ('name','last_visit','joined')
           then (case when (u.has_fee_due or u.has_duplicate or u.needs_waiver or u.has_unpaid_booking) then 0 else 1 end) end asc,
      u.last_visit_at desc nulls last,
      lower(coalesce(u.first_name,''))
  )
  select jsonb_build_object(
    'rows', coalesce((
      select jsonb_agg(row_to_json(f)) from (
        select * from filtered offset (v_page - 1) * v_size limit v_size
      ) f
    ), '[]'::jsonb),
    'counts', (select c from counts),
    'total', (select count(*) from filtered),
    'page', v_page,
    'page_size', v_size
  ) into v_result;

  return v_result;
end $$;
revoke all on function members_list(uuid, text, text, text, integer) from public, anon;
grant execute on function members_list(uuid, text, text, text, integer) to authenticated, service_role;

-- ============================================================================
-- Copy fix (no decision): the free_reservation_credited default body. Platform
-- default only; a studio override is untouched.
-- ============================================================================
update notification_templates set
  text_body = E'Hi {first_name},\n\nThanks for coming to {class_name} today. Your {fee} reservation fee has been added back to your account as credit. When you buy a class package or merchandise, the credit is applied towards the total at checkout.\n\nSee plans: {plans_url}',
  html_body = '<p>Hi {first_name},</p>
<p>Thanks for coming to <strong>{class_name}</strong> today. Your {fee} reservation fee has been added back to your account as credit. When you buy a class package or merchandise, the credit is applied towards the total at checkout.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{plans_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See plans</a></td></tr></table>
<p>{studio_name}</p>'
where key = 'free_reservation_credited';

-- --- Anon stays EXACTLY THIRTEEN (public_schedule kept its grant; members_list is desk-up) ---
do $mig$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % (want 13)', n; end if;
end $mig$;
