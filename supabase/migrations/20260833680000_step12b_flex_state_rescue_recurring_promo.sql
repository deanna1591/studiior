-- Step 12b: Decision 22(f) members see a flex class's state, Decision 95(b)
-- rescue emails point at the nearest flex class first, Decision 117(a)
-- recurring memberships can carry a promotion.
--
-- creates: occurrence_paid_count_run(uuid), occurrence_flex_state_run(uuid), member_flex_states(uuid, timestamptz, timestamptz, uuid), core_classes_for_rescue(uuid, uuid)
-- re-issues: plan_price_now_run(uuid, timestamptz), promotion_save(uuid, uuid, text, int, date, date, uuid[]), promotions_list(uuid, boolean), xendit_activate_success_internal(uuid, text, text), record_manual_payment_run(uuid, uuid, text, int, text, uuid, uuid, char, text, text, timestamptz, text), public_schedule(text, integer), free_first_eligible_classes_run(uuid, uuid, integer), free_first_class_list(uuid), flex_rescue_block(uuid), schedule_post_data_run(uuid, date, date, boolean, uuid)
--
-- Newest definitions this re-issues from:
--   plan_price_now_run, promotion_save, promotions_list, xendit_activate_success_internal,
--   record_manual_payment_run: 20260833670000_step12_promotions_return_credit.sql (87, 165, 314, 450, 694)
--   public_schedule: 20260833620000_decision116c_18c_18d.sql:307
--   free_first_eligible_classes_run / free_first_class_list: 20260833520000_decision113_114_delivery_consent.sql:628 / 683
--   core_classes_for_rescue / flex_rescue_block: 20260833330000_decision95_flex_rescue.sql:65 / 114
--   schedule_post_data_run: 20260833310000_decision93c_instructor_posts.sql:96
--
-- Anon stays EXACTLY FOURTEEN (asserted at the bottom).

-- ===========================================================================
-- 22(f). The count the running latch uses, in one place. Paid seats: booked,
-- attended, no-show or pending payment, minus an unpaid drop-in (Decision 81b).
-- The same predicate schedule_range's staff chip reads.
-- ===========================================================================
create function occurrence_paid_count_run(p_occurrence_id uuid)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int
    from bookings b
   where b.occurrence_id = p_occurrence_id
     and b.status in ('booked','attended','no_show','pending_payment')
     and not (coalesce(b.payment_source = 'drop_in', false)
              and not exists (select 1 from payments pmt
                               where pmt.booking_id = b.id
                                 and pmt.status in ('succeeded','partially_refunded')));
$$;
revoke execute on function occurrence_paid_count_run(uuid) from public, anon, authenticated;
grant  execute on function occurrence_paid_count_run(uuid) to service_role;

-- {flex, paid_count, min_bookings, reached_minimum, committed}. flex is the
-- EFFECTIVE tier (occurrence_guarantee_run demotes flex when the studio has flex
-- off), so a chip only ever shows where the studio runs flex.
create function occurrence_flex_state_run(p_occurrence_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
           'flex', g.tier = 'flex',
           'paid_count', occurrence_paid_count_run(o.id),
           'min_bookings', g.minimum,
           'reached_minimum', o.flex_reached_minimum_at is not null,
           'committed', o.committed_at is not null)
    from class_occurrences o
    cross join lateral occurrence_guarantee_run(o.id) g
   where o.id = p_occurrence_id;
$$;
revoke execute on function occurrence_flex_state_run(uuid) from public, anon, authenticated;
grant  execute on function occurrence_flex_state_run(uuid) to service_role;

-- The member Book, Home, class page and free picker ask this once per screen
-- (the occurrence_holds shape). Only flex classes the member can see come back,
-- so a studio without flex returns nothing and nothing draws.
create function member_flex_states(p_studio_id uuid, p_from timestamptz, p_to timestamptz,
                                   p_occurrence_id uuid default null)
returns table(occurrence_id uuid, paid_count int, min_bookings int,
              reached_minimum boolean, committed boolean)
language plpgsql stable security definer set search_path = public as $$
declare v_member uuid;
begin
  select id into v_member from members
   where studio_id = p_studio_id and user_id = auth.uid() and deleted_at is null;
  if v_member is null then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;
  return query
    select o.id, occurrence_paid_count_run(o.id), g.minimum,
           o.flex_reached_minimum_at is not null, o.committed_at is not null
      from class_occurrences o
      cross join lateral occurrence_guarantee_run(o.id) g
     where o.studio_id = p_studio_id
       and o.starts_at >= p_from and o.starts_at < p_to
       and o.status = 'scheduled'
       and not o.hidden_from_members
       and not coalesce(o.is_private, false)
       and g.tier = 'flex'
       and occurrence_member_visible_run(o.id, v_member)
       and (p_occurrence_id is null or o.id = p_occurrence_id);
end $$;
revoke execute on function member_flex_states(uuid, timestamptz, timestamptz, uuid) from public, anon;
grant  execute on function member_flex_states(uuid, timestamptz, timestamptz, uuid) to authenticated, service_role;

-- ===========================================================================
-- 95(b). The rescue list: flex classes one short first (nearest), then two
-- short while fewer than four rows, then core (a class with a booking first),
-- 8 rows at most. Each row carries its label. p_booking_id (optional) lets the
-- list leave out classes the member already holds and keeps a free first class
-- rescue core-only when free_first_core_only is on. The row shape changes, so
-- the old one-argument function is dropped.
-- ===========================================================================
drop function if exists core_classes_for_rescue(uuid);
create function core_classes_for_rescue(p_occurrence_id uuid, p_booking_id uuid default null)
returns table(occurrence_id uuid, name text, starts_at timestamptz, day_label text,
              time_label text, coach_first text, n_booked int, spots_left int,
              label text, kind text)
language plpgsql stable security definer set search_path = public as $function$
declare v_src class_occurrences%rowtype; s studios%rowtype; v_fmt text;
        v_member uuid; v_core_only boolean := false; v_free boolean := false;
begin
  select * into v_src from class_occurrences where id = p_occurrence_id;
  if not found then return; end if;
  select * into s from studios where id = v_src.studio_id;
  v_fmt := coalesce((select time_format from studio_settings where studio_id = v_src.studio_id), '24h');

  -- The booking says whose list this is; only its member, the desk or the
  -- service may pass it (it leaves out the classes that member holds).
  if p_booking_id is not null and not is_service_context()
     and not coalesce(is_desk_up(v_src.studio_id), false)
     and not exists (select 1 from bookings bk join members m on m.id = bk.member_id
                      where bk.id = p_booking_id and m.user_id = auth.uid()) then
    raise exception 'that is not your booking' using errcode = 'PT403';
  end if;

  if p_booking_id is not null then
    select b.member_id,
           (b.payment_source = 'comp' and exists (select 1 from guest_passes gp
              where gp.guest_booking_id = b.id and gp.host_member_id is null))
      into v_member, v_free
      from bookings b where b.id = p_booking_id;
    v_free := coalesce(v_free, false);
    if v_free then
      v_core_only := coalesce((select free_first_core_only from studio_settings
                                where studio_id = v_src.studio_id), false);
    end if;
  end if;

  return query
  with cand as (
    select o.id,
           coalesce(nullif(o.name, ''), ct.name) as name,
           o.starts_at,
           to_char(o.starts_at at time zone s.timezone, 'FMDy FMDD FMMon') as day_label,
           fmt_clock(o.starts_at, s.timezone, v_fmt) as time_label,
           split_part(coalesce(i.display_name, ''), ' ', 1) as coach_first,
           o.booked_count as n_booked,
           (o.capacity - occurrence_seats_taken(o.id) - occurrence_seats_held(o.id)) as spots_left,
           coalesce(o.guarantee_tier,
                    case when o.flex then 'flex'::guarantee_tier end,
                    cs.guarantee_tier,
                    case when cs.flex then 'flex'::guarantee_tier end,
                    'core') as cfg_tier,
           g.tier as eff_tier, g.minimum,
           o.flex_reached_minimum_at is not null or o.committed_at is not null as running
      from class_occurrences o
      join class_types ct on ct.id = o.class_type_id
      left join class_series cs on cs.id = o.series_id
      left join instructors i on i.id = o.instructor_id
      cross join lateral occurrence_guarantee_run(o.id) g
     where o.studio_id = v_src.studio_id
       and o.id <> p_occurrence_id
       and o.status = 'scheduled'
       and not o.hidden_from_members
       and not coalesce(o.is_private, false)
       and occurrence_published(o.id)
       and o.starts_at > now()
       and o.starts_at >= v_src.starts_at
       and o.starts_at < v_src.starts_at + interval '7 days'
       and (o.capacity - occurrence_seats_taken(o.id) - occurrence_seats_held(o.id)) >= 1
       and (v_member is null or not exists (
             select 1 from bookings mb where mb.occurrence_id = o.id and mb.member_id = v_member
                and mb.status in ('booked','attended','pending_payment','waitlisted')))
  ),
  short as (
    select c.*, (c.minimum - occurrence_paid_count_run(c.id)) as need
      from cand c
     where not v_core_only
       and c.eff_tier = 'flex' and not c.running and coalesce(c.minimum, 0) > 0
  ),
  one_short as (
    select s1.*, row_number() over (order by s1.starts_at) as rn
      from short s1 where s1.need = 1
  ),
  two_short as (
    select s2.*, row_number() over (order by s2.starts_at) as rn
      from short s2 where s2.need = 2
  ),
  n1 as (select count(*)::int as n from one_short),
  core as (
    select c.*, row_number() over (order by (c.n_booked > 0) desc, c.starts_at) as rn
      from cand c where c.cfg_tier = 'core'
  ),
  picked as (
    select o1.id, o1.name, o1.starts_at, o1.day_label, o1.time_label, o1.coach_first,
           o1.n_booked, o1.spots_left, 'Needs 1 more'::text as label, 'flex'::text as kind,
           1 as grp, o1.rn
      from one_short o1
    union all
    select t2.id, t2.name, t2.starts_at, t2.day_label, t2.time_label, t2.coach_first,
           t2.n_booked, t2.spots_left, 'Needs 2 more', 'flex', 2, t2.rn
      from two_short t2, n1
     where n1.n + t2.rn <= 4 and n1.n < 4
    union all
    select k.id, k.name, k.starts_at, k.day_label, k.time_label, k.coach_first,
           k.n_booked, k.spots_left, 'Always runs', 'core', 3, k.rn
      from core k
  )
  select p.id, p.name, p.starts_at, p.day_label, p.time_label, p.coach_first,
         p.n_booked, p.spots_left, p.label, p.kind
    from picked p
   order by p.grp, p.rn
   limit 8;
end $function$;
revoke execute on function core_classes_for_rescue(uuid, uuid) from public, anon;
grant  execute on function core_classes_for_rescue(uuid, uuid) to authenticated, service_role;

-- The intro sentence above the list, on the four platform defaults. Reform's
-- overrides are left as they are; their {class_list_core} still fills.
update notification_templates
   set text_body = replace(replace(replace(text_body,
         'Want a class that is already running? Move your spot in one tap:', 'Pick one that needs you, or one that always runs:'),
         'Want a class that is already running? Move your free spot in one tap:', 'Pick one that needs you, or one that always runs:'),
         'Move to a class that is already going ahead in one tap:', 'Pick one that needs you, or one that always runs:'),
       html_body = replace(replace(replace(html_body,
         'Want a class that is already running? Move your spot in one tap:', 'Pick one that needs you, or one that always runs:'),
         'Want a class that is already running? Move your free spot in one tap:', 'Pick one that needs you, or one that always runs:'),
         'Move to a class that is already going ahead in one tap:', 'Pick one that needs you, or one that always runs:')
 where key in ('flex_rescue_2days', 'flex_rescue_final', 'free_rescue_2days', 'free_rescue_final');

-- flex_rescue_block re-issued (20260833330000:114): the booking goes to the list, and each card carries its label.
create or replace function flex_rescue_block(p_booking_id uuid)
returns table(html text, txt text)
language plpgsql stable security definer set search_path = public as $function$
declare
  v_b bookings%rowtype; v_src class_occurrences%rowtype;
  v_cards_html text := ''; v_cards_txt text := ''; r record; v_n int := 0;
  v_move text; v_book text; v_detail text;
begin
  select * into v_b from bookings where id = p_booking_id;
  if not found then return; end if;
  select * into v_src from class_occurrences where id = v_b.occurrence_id;
  v_book := member_portal_url(v_src.studio_id, '/book');

  for r in select * from core_classes_for_rescue(v_src.id, p_booking_id) loop
    v_n := v_n + 1;
    v_move := member_portal_url(v_src.studio_id, '/move?booking=' || p_booking_id::text || '&target=' || r.occurrence_id::text);
    v_detail := concat_ws(' · ', r.day_label, r.time_label, nullif('with ' || r.coach_first, 'with '));
    v_cards_html := v_cards_html
      || '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:12px 0">'
      || '<tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px">'
      || '<div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:12px;font-weight:600;line-height:16px;color:#57534E;text-transform:none;margin-bottom:4px">' || r.label || '</div>'
      || '<div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">' || r.name || '</div>'
      || '<div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">' || v_detail || '</div>'
      || '<div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:13px;line-height:18px;color:#78716C;margin-top:2px">'
      || (case when r.n_booked > 0 then r.n_booked || ' in already · ' else '' end) || r.spots_left || ' spots left</div>'
      || '<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin-top:12px"><tr><td style="border-radius:6px;background:{accent}">'
      || '<a href="' || v_move || '" style="display:inline-block;padding:10px 20px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Move me to this class</a>'
      || '</td></tr></table>'
      || '</td></tr></table>';
    v_cards_txt := v_cards_txt || '- ' || r.label || ': ' || r.name || ' · ' || v_detail
      || ' (' || (case when r.n_booked > 0 then r.n_booked || ' in already, ' else '' end) || r.spots_left || ' spots left): ' || v_move || E'\n';
  end loop;

  if v_n = 0 then
    html := '<p><a href="' || v_book || '">See the full schedule</a></p>';
    txt  := 'See the full schedule: ' || v_book;
  else
    html := v_cards_html
      || '<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}">'
      || '<a href="' || v_book || '" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See the full schedule</a>'
      || '</td></tr></table>';
    txt := v_cards_txt || E'\nSee the full schedule: ' || v_book;
  end if;
  return next;
end $function$;
revoke execute on function flex_rescue_block(uuid) from public, anon, authenticated;
grant  execute on function flex_rescue_block(uuid) to service_role;

-- public_schedule re-issued (20260833620000:307): + the flex state per class.
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
  v_gift boolean;
  v_priv boolean;         -- 116(c): the embed links to the private sessions page         -- 110(a): the embed links to the gift page when gift cards are on
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
  select coalesce(gift_enabled, false) into v_gift
    from studio_settings where studio_id = v_studio.id;
  v_gift := coalesce(v_gift, false);
  select coalesce(private_sessions_enabled, false) into v_priv
    from studio_settings where studio_id = v_studio.id;
  v_priv := coalesce(v_priv, false);
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
        -- Decision 22(f): the flex state for the chip (null when not flex).
        case when (fs ->> 'flex')::boolean then (fs ->> 'paid_count')::int end       as paid_count,
        case when (fs ->> 'flex')::boolean then (fs ->> 'min_bookings')::int end     as min_bookings,
        case when (fs ->> 'flex')::boolean then (fs ->> 'reached_minimum')::boolean end as reached_minimum,
        case when (fs ->> 'flex')::boolean then (fs ->> 'committed')::boolean end    as committed,
        coalesce((fs ->> 'flex')::boolean, false)                     as flex,
        (o.booked_count >= o.capacity)                                 as full,
        'https://' || v_studio.slug || '.studiior.app/class/' || o.id  as book_url
      from class_occurrences o
      join class_types ct on ct.id = o.class_type_id
      left join class_series cs on cs.id = o.series_id
      left join instructors i on i.id = o.instructor_id
      left join rooms r on r.id = o.room_id
      cross join lateral (select occurrence_flex_state_run(o.id) as fs) fsx
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
      'guarantees_enabled', v_guar,
      'gift_enabled',       v_gift,
      'gift_url',           case when v_gift then 'https://' || v_studio.slug || '.studiior.app/gift' end,
      'private_enabled',    v_priv,
      'private_url',        case when v_priv then 'https://' || v_studio.slug || '.studiior.app/book/private' end
    ),
    'classes', v_classes
  );

  insert into public_schedule_cache (slug, days, payload, computed_at)
  values (v_studio.slug, v_days, v_payload, now())
  on conflict (slug, days) do update
    set payload = excluded.payload, computed_at = excluded.computed_at;

  return v_payload;
end $function$;
revoke execute on function public_schedule(text, integer) from public;
grant  execute on function public_schedule(text, integer) to anon, authenticated, service_role;
delete from public_schedule_cache;

-- free_first_eligible_classes_run / free_first_class_list re-issued
-- (20260833520000:628 / 683): + the flex state columns. The row shape changes,
-- so both are dropped and created; grants re-applied.
drop function if exists free_first_class_list(uuid);
drop function if exists free_first_eligible_classes_run(uuid, uuid, integer);
create function free_first_eligible_classes_run(p_studio_id uuid, p_member_id uuid, p_min_headcount integer default 0)
returns table(occurrence_id uuid, name text, starts_at timestamptz, duration_min integer,
              room_name text, instructor_first text, instructor_avatar text,
              headcount integer, capacity integer, free_bookable boolean,
              occ_flex boolean, occ_paid_count integer, occ_min integer,
              occ_reached_minimum boolean, occ_committed boolean)
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare st studio_settings%rowtype; v_elig jsonb;
begin
  select * into st from studio_settings where studio_id = p_studio_id;
  v_elig := free_first_eligibility(p_studio_id, p_member_id);
  if not coalesce((v_elig ->> 'ok')::boolean, false) then return; end if;

  return query
  select o.id, o.name, o.starts_at,
         coalesce(ct.duration_minutes, 0),
         (select r.name from rooms r where r.id = o.room_id),
         (select split_part(i.display_name, ' ', 1) from instructors i where i.id = o.instructor_id),
         (select i.avatar_url from instructors i where i.id = o.instructor_id),
         coalesce(o.booked_count, 0), o.capacity,
         ( o.capacity - occurrence_seats_taken(o.id) - occurrence_seats_held(o.id) >= 1
           and (st.free_first_seats_per_class is null
                or (select count(*) from bookings b
                     where b.occurrence_id = o.id and b.status = 'booked'
                       and b.payment_source = 'comp'
                       and exists (select 1 from guest_passes gp
                                    where gp.guest_booking_id = b.id and gp.host_member_id is null))
                    < st.free_first_seats_per_class) ),
         coalesce((fsx.fs ->> 'flex')::boolean, false),
         (fsx.fs ->> 'paid_count')::int, (fsx.fs ->> 'min_bookings')::int,
         (fsx.fs ->> 'reached_minimum')::boolean, (fsx.fs ->> 'committed')::boolean
    from class_occurrences o
    cross join lateral (select occurrence_flex_state_run(o.id) as fs) fsx
    left join class_series ser on ser.id = o.series_id
    left join class_types  ct  on ct.id  = o.class_type_id
   where o.studio_id = p_studio_id
     and o.status = 'scheduled' and not o.hidden_from_members
     and o.starts_at > now()
     and o.starts_at <= now() + make_interval(days => coalesce(st.booking_window_days, 30))
     and o.starts_at >= now() + make_interval(mins => coalesce(st.booking_cutoff_minutes, 0))
     and occurrence_member_visible_run(o.id, p_member_id)
     and o.free_first_override is distinct from 'closed'
     and (o.free_first_override = 'open' or (
            (not coalesce(st.free_first_core_only, false)
             or coalesce(o.guarantee_tier, case when o.flex then 'flex'::guarantee_tier end,
                         ser.guarantee_tier, case when ser.flex then 'flex'::guarantee_tier end,
                         'core'::guarantee_tier) = 'core')
            and (o.series_id is null or coalesce(ser.free_first_allowed, true))
          ))
     and not (not coalesce(st.free_first_peak_allowed, true) and occurrence_is_peak(o.id))
     and coalesce(o.booked_count, 0) >= p_min_headcount
   order by coalesce(o.booked_count, 0) desc, o.starts_at;
end $function$;
revoke all on function free_first_eligible_classes_run(uuid, uuid, integer) from public, anon, authenticated;
grant execute on function free_first_eligible_classes_run(uuid, uuid, integer) to service_role;
create function free_first_class_list(p_studio_id uuid)
returns table(occurrence_id uuid, name text, starts_at timestamptz, duration_min integer,
              room_name text, instructor_first text, instructor_avatar text,
              headcount integer, capacity integer, free_bookable boolean,
              occ_flex boolean, occ_paid_count integer, occ_min integer,
              occ_reached_minimum boolean, occ_committed boolean)
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare v_member uuid;
begin
  select id into v_member from members where user_id = auth.uid() and studio_id = p_studio_id;
  if v_member is null then
    raise exception 'not a member of that studio' using errcode = 'PT403';
  end if;
  return query select * from free_first_eligible_classes_run(p_studio_id, v_member, 0);
end $function$;
revoke all on function free_first_class_list(uuid) from public, anon;
grant execute on function free_first_class_list(uuid) to authenticated, service_role;

-- plan_price_now_run re-issued (20260833670000:87): recurring plans included; + plan_type, billing_interval.
create or replace function plan_price_now_run(p_plan_id uuid, p_at timestamptz default now())
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare mp membership_plans%rowtype; v_tz text; pp plan_promotions%rowtype; v_sale int;
begin
  select * into mp from membership_plans where id = p_plan_id;
  if not found then return null; end if;
  select timezone into v_tz from studios where id = mp.studio_id;
  -- Decision 117(a): recurring plans are eligible too; the sale applies to each
  -- period paid for while the promotion runs.
    select p.* into pp
      from plan_promotions p
     where p.studio_id = mp.studio_id and mp.id = any (p.plan_ids) and p.archived_at is null
       and p_at >= (p.starts_on::timestamp at time zone v_tz)
       and p_at <  ((p.ends_on + 1)::timestamp at time zone v_tz)
       and (p.ended_at is null or p_at < p.ended_at)
     order by p.created_at
     limit 1;
  if pp.id is null then
    return jsonb_build_object('plan_id', mp.id, 'list_cents', mp.price_cents, 'price_cents', mp.price_cents,
      'discount_cents', 0, 'currency', mp.currency, 'promotion_id', null, 'promotion_name', null,
      'pct', null, 'ends_on', null, 'ends_label', null,
      'plan_type', mp.type, 'billing_interval', mp.billing_interval);
  end if;
  v_sale := promo_sale_cents(mp.price_cents, pp.pct);
  return jsonb_build_object('plan_id', mp.id, 'list_cents', mp.price_cents, 'price_cents', v_sale,
    'discount_cents', mp.price_cents - v_sale, 'currency', mp.currency,
    'promotion_id', pp.id, 'promotion_name', pp.name, 'pct', pp.pct,
    'ends_on', pp.ends_on, 'ends_label', to_char(pp.ends_on, 'FMDy FMDD FMMon'),
    'plan_type', mp.type, 'billing_interval', mp.billing_interval);
end $$;
revoke execute on function plan_price_now_run(uuid, timestamptz) from public, anon, authenticated;
grant  execute on function plan_price_now_run(uuid, timestamptz) to service_role;

-- promotion_save re-issued (20260833670000:165): the plan_recurring refusal removed (117 a).
create or replace function promotion_save(
  p_studio_id uuid, p_promotion_id uuid, p_name text, p_pct int,
  p_starts_on date, p_ends_on date, p_plan_ids uuid[])
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_tz text; v_today date; v_old plan_promotions%rowtype; v_id uuid; v_name text;
        r record; v_ids uuid[];
begin
  if not coalesce(is_manager_up(p_studio_id), false) then
    raise exception 'only owners and managers set promotions' using errcode = 'PT403';
  end if;
  select timezone into v_tz from studios where id = p_studio_id;
  v_today := (now() at time zone v_tz)::date;
  v_name := btrim(coalesce(p_name, ''));
  v_ids := array(select distinct unnest(coalesce(p_plan_ids, '{}'::uuid[])));

  if p_promotion_id is not null then
    select * into v_old from plan_promotions where id = p_promotion_id and studio_id = p_studio_id;
    if not found then raise exception 'no such promotion' using errcode = 'PT404'; end if;
    if v_old.archived_at is not null or v_old.ended_at is not null
       or now() >= (v_old.starts_on::timestamp at time zone v_tz) then
      return jsonb_build_object('ok', false, 'reason', 'started',
        'message', 'This promotion has started. End it and create a new one.');
    end if;
  end if;

  if v_name = '' or length(v_name) > 60 then
    return jsonb_build_object('ok', false, 'reason', 'name_required', 'message', 'Give the promotion a name.');
  end if;
  if p_pct is null or p_pct < 1 or p_pct > 90 then
    return jsonb_build_object('ok', false, 'reason', 'pct_range',
      'message', 'The percent off is a whole number from 1 to 90.');
  end if;
  if p_starts_on is null or p_ends_on is null or p_ends_on < p_starts_on then
    return jsonb_build_object('ok', false, 'reason', 'dates', 'message', 'The end date is before the start date.');
  end if;
  if p_starts_on < v_today then
    return jsonb_build_object('ok', false, 'reason', 'start_past', 'message', 'The start date is in the past.');
  end if;
  if coalesce(array_length(v_ids, 1), 0) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_plans', 'message', 'Tick at least one plan.');
  end if;

  for r in select u.id, mp.id as plan_id, mp.name, mp.type, mp.status
             from unnest(v_ids) u(id)
             left join membership_plans mp on mp.id = u.id and mp.studio_id = p_studio_id loop
    if r.plan_id is null or r.status = 'archived' then
      return jsonb_build_object('ok', false, 'reason', 'plan_unknown', 'message', 'One of those plans is not on sale here.');
    end if;
  end loop;

  -- One promotion per plan at a time: no overlap with another live or scheduled one.
  for r in select mp.name as plan_name, pp.name as other, pp.starts_on,
                  case when pp.ended_at is not null then (pp.ended_at at time zone v_tz)::date
                       else pp.ends_on end as other_end
             from plan_promotions pp
             join membership_plans mp on mp.id = any (pp.plan_ids)
            where pp.studio_id = p_studio_id and pp.archived_at is null
              and pp.id is distinct from p_promotion_id
              and mp.id = any (v_ids)
              -- an ended promotion only overlaps on time it still had to run
              and (pp.ended_at is null
                   or pp.ended_at > greatest((p_starts_on::timestamp at time zone v_tz), now()))
              and pp.starts_on <= p_ends_on
              and (case when pp.ended_at is not null then (pp.ended_at at time zone v_tz)::date
                        else pp.ends_on end) >= p_starts_on
            order by mp.name limit 1 loop
    return jsonb_build_object('ok', false, 'reason', 'overlap',
      'message', r.plan_name || ' already has ' || r.other || ' from '
                 || to_char(r.starts_on, 'FMDy FMDD FMMon') || ' to ' || to_char(r.other_end, 'FMDy FMDD FMMon') || '.');
  end loop;

  if p_promotion_id is null then
    insert into plan_promotions (studio_id, name, pct, starts_on, ends_on, plan_ids, created_by)
    values (p_studio_id, v_name, p_pct, p_starts_on, p_ends_on, v_ids, auth.uid())
    returning id into v_id;
  else
    update plan_promotions set name = v_name, pct = p_pct, starts_on = p_starts_on, ends_on = p_ends_on,
           plan_ids = v_ids, updated_at = now()
     where id = p_promotion_id;
    v_id := p_promotion_id;
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
  values (p_studio_id, auth.uid(),
          case when p_promotion_id is null then 'promotion.created' else 'promotion.updated' end,
          'plan_promotions', v_id,
          case when p_promotion_id is null then null else to_jsonb(v_old) end,
          (select to_jsonb(pp) from plan_promotions pp where pp.id = v_id));
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;
revoke execute on function promotion_save(uuid, uuid, text, int, date, date, uuid[]) from public, anon;
grant  execute on function promotion_save(uuid, uuid, text, int, date, date, uuid[]) to authenticated, service_role;

-- promotions_list re-issued (20260833670000:314): a recurring plan reads "{name} (monthly)".
create or replace function promotions_list(p_studio_id uuid, p_include_archived boolean default false)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(is_manager_up(p_studio_id), false) and not is_service_context() then
    raise exception 'only owners and managers see promotions' using errcode = 'PT403';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', pp.id, 'name', pp.name, 'pct', pp.pct,
      'starts_on', pp.starts_on, 'ends_on', pp.ends_on, 'ended_at', pp.ended_at,
      'archived_at', pp.archived_at,
      'status', case when pp.archived_at is not null then 'archived'
                     when now() < b.start_at then 'scheduled'
                     when now() < b.end_at then 'running'
                     else 'ended' end,
      'plan_ids', to_jsonb(pp.plan_ids),
      'plan_names', (select coalesce(jsonb_agg(mp.name
                         || case when mp.type = 'recurring' then
                              ' (' || case mp.billing_interval when 'week' then 'weekly' when 'month' then 'monthly'
                                        when 'quarter' then 'quarterly' when 'year' then 'yearly' else 'recurring' end || ')'
                            else '' end order by mp.name), '[]'::jsonb)
                       from membership_plans mp where mp.id = any (pp.plan_ids)),
      'sold', (select count(*) from payments p where p.promotion_id = pp.id
                 and p.status in ('succeeded', 'partially_refunded')),
      'discount_cents', (select coalesce(sum(p.discount_cents), 0) from payments p where p.promotion_id = pp.id
                 and p.status in ('succeeded', 'partially_refunded')))
      order by pp.starts_on desc, pp.created_at desc)
      from plan_promotions pp
      cross join lateral promotion_bounds(pp.id) b
     where pp.studio_id = p_studio_id and (p_include_archived or pp.archived_at is null)), '[]'::jsonb);
end $$;
revoke execute on function promotions_list(uuid, boolean) from public, anon;
grant  execute on function promotions_list(uuid, boolean) to authenticated, service_role;

-- xendit_activate_success_internal re-issued (20260833670000:450): a recurring membership on sale keeps its list rate.
create or replace function xendit_activate_success_internal(p_purchase_id uuid, p_payment_id text, p_source text default 'xendit')
returns text
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype; v_ms uuid; v_prior text;
        v_group uuid; v_is_group boolean;
        o product_orders%rowtype; prod products%rowtype;
        v_b bookings%rowtype; v_occ class_occurrences%rowtype; v_free int; v_pay_id uuid;
        gc gift_cards%rowtype; v_code text; v_prov payment_provider; v_src text; v_ref text; v_send timestamptz;
begin
  select * into p from xendit_purchases where id = p_purchase_id for update;
  if p.id is null then return 'unknown_purchase'; end if;
  if p.status = 'succeeded' then return 'already_succeeded'; end if;
  v_prior := p.status;

  -- A full-credit (Decision 103(f)) completion: the payment row is source credit,
  -- provider manual, no processor reference.
  v_prov := case when p_source = 'credit' then 'manual'::payment_provider else 'xendit'::payment_provider end;
  v_src  := nullif(p_source, 'xendit');
  v_ref  := case when p_source = 'credit' then null else nullif(p_payment_id, '') end;

  if p.booking_id is not null then
    insert into payments (studio_id, member_id, booking_id, kind, amount_cents, currency,
                          status, provider, source, reference, description, paid_at)
    values (p.studio_id, p.member_id, p.booking_id, 'reservation_fee', p.amount_cents, p.currency,
            'succeeded', v_prov, v_src, v_ref, 'Reservation fee', now())
    returning id into v_pay_id;
    select * into v_b from bookings where id = p.booking_id;
    if v_b.status in ('booked', 'pending_payment') then
      perform book_first_free_run(p.booking_id);
    else
      select * into v_occ from class_occurrences where id = v_b.occurrence_id;
      v_free := coalesce(v_occ.capacity, 0) - occurrence_seats_taken(v_occ.id)
                - occurrence_seats_held(v_occ.id);
      if v_occ.id is not null and v_occ.status = 'scheduled'
         and v_occ.starts_at > now() and v_free >= 1 then
        perform restore_reservation_booking(p.booking_id);
      else
        insert into member_credits (studio_id, member_id, amount_cents, currency, reason,
                                    payment_id, booking_id)
        values (p.studio_id, p.member_id, p.amount_cents, p.currency, 'reservation_lost_seat',
                v_pay_id, p.booking_id);
        perform queue_notification(p.studio_id, p.member_id, 'free_reservation_lost_seat',
          jsonb_build_object('fee', fmt_money(p.amount_cents, p.currency),
            'class_name', coalesce(v_occ.name, 'a class'),
            'plans_url', member_portal_url(p.studio_id, '/account/plan')),
          'free_reservation_lost_seat:' || p.booking_id::text);
      end if;
    end if;

  elsif p.gift_card_id is not null then
    -- Decision 110: issue the gift card. Mint the code, record the sale (a real
    -- payment, so it counts in revenue once; linked by gift_card_id). Email the
    -- buyer at once; schedule the recipient for the delivery date (now when none).
    select * into gc from gift_cards where id = p.gift_card_id for update;
    v_code := gift_code(p.studio_id);
    -- Decision 110(a): the composited card image (amount + code over the studio's
    -- card) is served by the member host's next/og route; its path is stored on
    -- the card at issue and carried on gift_card_sent.
    update gift_cards set status = 'active', code = v_code, issued_at = now(),
           card_image_path = '/giftcard/' || gc.id::text || '/' || v_code || '/' || gc.amount_cents::text
     where id = gc.id and status in ('pending', 'active');

    insert into payments (studio_id, member_id, gift_card_id, kind, amount_cents, currency,
                          status, provider, source, reference, description, paid_at)
    values (p.studio_id, p.member_id, gc.id, 'gift_card', p.amount_cents, p.currency,
            'succeeded', v_prov, v_src, v_ref, 'Gift card', now());

    perform queue_notification(p.studio_id, gc.buyer_member_id, 'gift_card_receipt',
      jsonb_build_object('to_email', gc.buyer_email, 'buyer_name', coalesce(gc.buyer_name, 'there'),
        'recipient_name', coalesce(gc.recipient_name, 'your friend'),
        'code', v_code, 'amount', fmt_money(p.amount_cents, p.currency),
        'studio_name', (select name from studios where id = p.studio_id)),
      'gift_card_receipt:' || gc.id::text);

    v_send := case
      when gc.delivery_date is null then now()
      else greatest(now(),
        ((gc.delivery_date::text || ' 08:00')::timestamp
          at time zone (select timezone from studios where id = p.studio_id))) end;
    perform queue_notification(p.studio_id, gc.redeemed_by_member_id, 'gift_card_sent',
      jsonb_build_object('to_email', gc.recipient_email,
        'recipient_name', coalesce(gc.recipient_name, 'there'),
        'buyer_name', coalesce(gc.buyer_name, 'A friend'),
        'code', v_code, 'amount', fmt_money(p.amount_cents, p.currency),
        'message', coalesce(gc.message, ''),
        'message_html', case when coalesce(btrim(gc.message), '') = '' then ''
          else '<p style="font-style:italic;color:#57534e">&ldquo;' || replace(replace(replace(gc.message, '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || '&rdquo;</p>' end,
        'card_image_url', member_portal_url(p.studio_id,
          '/giftcard/' || gc.id::text || '/' || v_code || '/' || gc.amount_cents::text),
        'redeem_url', member_portal_url(p.studio_id, '/account/redeem'),
        'studio_name', (select name from studios where id = p.studio_id)),
      'gift_card_sent:' || gc.id::text, v_send);

  elsif p.private_occurrence_id is not null then
    -- Decision 116: a full-paid private. Record the 'private' payment against the
    -- booker's seat (so Sales buckets it by the occurrence), then confirm the
    -- session at once (commit, flip seats, tell everyone, write the flat pay line).
    insert into payments (studio_id, member_id, booking_id, kind, amount_cents, currency,
                          status, provider, source, reference, description, paid_at)
    select p.studio_id, p.member_id, (select b.id from bookings b
             where b.occurrence_id = p.private_occurrence_id and b.payment_source = 'private'
             order by b.created_at limit 1),
           'private', p.amount_cents, p.currency, 'succeeded', v_prov, v_src, v_ref,
           'Private session', now()
    returning id into v_pay_id;
    select * into v_occ from class_occurrences where id = p.private_occurrence_id;
    if v_occ.status = 'scheduled' and v_occ.starts_at > now() then
      perform private_confirm_run(p.private_occurrence_id);
    else
      -- a late success on a private already released (expired session): the
      -- money is never lost, it lands as account credit (the 103(e) rule).
      insert into member_credits (studio_id, member_id, amount_cents, currency, reason, payment_id)
      values (p.studio_id, p.member_id, p.amount_cents, p.currency, 'private_refund', v_pay_id);
    end if;

  elsif p.product_order_id is not null then
    select * into o from product_orders where id = p.product_order_id for update;
    select * into prod from products where id = o.product_id for update;

    update product_orders set status = 'paid' where id = o.id and status in ('reserved', 'pending');

    if prod.track_stock then
      update products set stock = stock + o.quantity where id = prod.id;
      insert into stock_movements (studio_id, product_id, delta, reason, order_id)
      values (p.studio_id, prod.id, o.quantity, 'release', o.id);
      update products set stock = stock - o.quantity where id = prod.id;
      insert into stock_movements (studio_id, product_id, delta, reason, order_id)
      values (p.studio_id, prod.id, -o.quantity, 'sale', o.id);
    end if;

    insert into payments (studio_id, member_id, product_order_id, amount_cents, currency,
                          status, provider, source, reference, description, paid_at)
    values (p.studio_id, p.member_id, o.id, p.amount_cents, p.currency, 'succeeded', v_prov,
            v_src, v_ref, prod.name || ' ×' || o.quantity, now());

    perform queue_notification(
      p.studio_id, p.member_id, 'product_order_paid',
      jsonb_build_object('product', prod.name, 'quantity', o.quantity),
      'product_order_paid:' || o.id::text);

  else
    select type = 'group' into v_is_group from membership_plans where id = p.plan_id;
    if v_is_group then
      v_group := activate_purchase(p.studio_id, p.member_id, p.plan_id, p.amount_cents, p.currency, null, null, false);
      insert into payments (studio_id, member_id, group_purchase_id, amount_cents, currency,
                            status, provider, source, reference, description, paid_at,
                            list_price_cents, promotion_id, discount_cents)
      select p.studio_id, p.member_id, v_group, p.amount_cents, p.currency, 'succeeded', v_prov,
             v_src, v_ref, mp.name, now(), p.list_price_cents, p.promotion_id, p.discount_cents
        from membership_plans mp where mp.id = p.plan_id;
    else
    if p.renews_membership_id is not null and exists (
         select 1 from memberships where id = p.renews_membership_id
            and status in ('active', 'past_due') and not membership_frozen_now(id)) then
      v_ms := p.renews_membership_id;
      perform advance_membership_period_run(p.renews_membership_id);
    else
      v_ms := activate_purchase(p.studio_id, p.member_id, p.plan_id, p.amount_cents, p.currency,
                                null, null, false);
      update memberships set auto_renew = false where id = v_ms;
      -- Decision 117(a): a recurring membership bought on sale keeps the list
      -- price as its rate; the discount belongs to this period's payment.
      if p.promotion_id is not null and p.list_price_cents is not null then
        update memberships ms set price_cents = p.list_price_cents
          from membership_plans pl
         where ms.id = v_ms and pl.id = ms.plan_id and pl.type = 'recurring';
      end if;
    end if;

    perform apply_plan_to_unpaid(p.studio_id, p.member_id, v_ms);

    insert into payments (studio_id, member_id, membership_id, amount_cents, currency,
                          status, provider, source, reference, description, paid_at,
                          list_price_cents, promotion_id, discount_cents)
    select p.studio_id, p.member_id, v_ms, p.amount_cents, p.currency, 'succeeded', v_prov,
           v_src, v_ref, mp.name, now(), p.list_price_cents, p.promotion_id, p.discount_cents
      from membership_plans mp where mp.id = p.plan_id;
    end if;
  end if;

  -- ONE consume: a plan/product (and reservation, when not via reserve_free_first)
  -- purchase consumes any reservation/gift credit applied at begin. A gift sale
  -- never carries credit_applied, so this is a no-op there.
  if p.credit_applied_cents > 0 then
    perform consume_reservation_credit(p.studio_id, p.member_id, p.credit_applied_cents);
  end if;

  if v_prior = 'expired' then
    insert into audit_logs (studio_id, action, entity_table, entity_id, after)
    values (p.studio_id, 'xendit.expiry_overridden', 'xendit_purchases', p.id,
            jsonb_build_object('prior_status', v_prior,
                               'payment_id', nullif(p_payment_id, ''),
                               'note', 'paid after local expiry'));
  end if;

  update xendit_purchases
     set status = 'succeeded', xendit_payment_id = nullif(p_payment_id, ''),
         completed_at = now(), failure_reason = null, updated_at = now()
   where id = p_purchase_id;

  return case when v_prior = 'expired' then 'activated_after_expiry' else 'activated' end;
end $$;
revoke execute on function xendit_activate_success_internal(uuid, text, text) from public, anon, authenticated;
grant  execute on function xendit_activate_success_internal(uuid, text, text) to service_role;

-- record_manual_payment_run re-issued (20260833670000:694): a new recurring membership on sale keeps its list rate.
create or replace function record_manual_payment_run(
  p_studio_id uuid, p_member_id uuid, p_kind text, p_amount_cents integer, p_method text,
  p_plan_id uuid default null, p_booking_id uuid default null, p_currency char default null,
  p_method_note text default null, p_reference text default null,
  p_paid_at timestamptz default now(), p_description text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_currency char(3);
  v_ms       uuid;
  v_payment  uuid;
  v_confirmed boolean := false;
  v_plan_name text;
  v_renewing uuid;
  v_renewal  jsonb;
  v_is_group boolean := false;
  v_group_purchase uuid;
  v_pr jsonb; v_list int; v_promo uuid; v_disc int;
begin
  if studio_is_locked(p_studio_id) then
    raise exception 'this studio''s Studiior subscription is not active'
      using errcode = 'PT402',
            hint = 'Reactivate it from Billing. Nothing has been deleted.';
  end if;

  if p_amount_cents is null or p_amount_cents < 0 then
    raise exception 'an amount is needed' using errcode = 'PT400';
  end if;
  if not exists (select 1 from members where id = p_member_id and studio_id = p_studio_id) then
    raise exception 'that member does not belong to this studio' using errcode = 'PT403';
  end if;

  select coalesce(p_currency, s.currency) into v_currency
    from studios s where s.id = p_studio_id;

  if p_kind = 'plan' then
    if p_plan_id is null then
      raise exception 'which plan?' using errcode = 'PT400';
    end if;
    select ms.id into v_renewing
      from memberships ms
      join membership_plans pl on pl.id = ms.plan_id
     where ms.studio_id = p_studio_id and ms.member_id = p_member_id
       and ms.plan_id = p_plan_id
       and pl.type = 'recurring'
       and ms.status in ('active', 'past_due')
     order by ms.current_period_end desc nulls last
     limit 1;

    if v_renewing is not null then
      v_ms := v_renewing;
      -- The UNGUARDED twin: record_manual_payment_run is also reached from the
      -- instructor desk (sell_plan_at_desk), where the caller is not desk/service
      -- and advance_membership_period's own guard would refuse. The desk/scope
      -- boundary is enforced by the caller (is_desk_up wrapper / instructor_scope).
      v_renewal := advance_membership_period_run(v_renewing);
    else
      v_ms := activate_purchase(p_studio_id, p_member_id, p_plan_id,
                                p_amount_cents, v_currency);
    end if;
    select name, type = 'group' into v_plan_name, v_is_group
      from membership_plans where id = p_plan_id;
    if v_is_group then v_group_purchase := v_ms; v_ms := null; end if;

  elsif p_kind = 'dropin' then
    if p_booking_id is null then
      raise exception 'which booking?' using errcode = 'PT400';
    end if;
    v_confirmed := confirm_dropin_payment(p_studio_id, p_booking_id);
  end if;

  -- Decision 117: the promotion is recorded only when the amount IS the sale
  -- price; any other typed amount is a manual price, recorded as typed.
  if p_kind = 'plan' and p_plan_id is not null then
    v_pr := plan_price_now_run(p_plan_id, now());
    if nullif(v_pr ->> 'promotion_id', '') is not null
       and p_amount_cents = (v_pr ->> 'price_cents')::int then
      v_promo := (v_pr ->> 'promotion_id')::uuid;
      v_list  := (v_pr ->> 'list_cents')::int;
      v_disc  := (v_pr ->> 'discount_cents')::int;
      -- Decision 117(a): a new recurring membership sold on sale keeps the
      -- list price as its rate (a renewal never changes the rate).
      if v_ms is not null and v_renewing is null then
        update memberships ms set price_cents = v_list
          from membership_plans pl
         where ms.id = v_ms and pl.id = ms.plan_id and pl.type = 'recurring';
      end if;
    end if;
  end if;

  insert into payments (
    studio_id, member_id, membership_id, group_purchase_id, booking_id, amount_cents, currency,
    status, provider, method, method_note, reference, description,
    paid_at, recorded_by, list_price_cents, promotion_id, discount_cents
  ) values (
    p_studio_id, p_member_id, v_ms, v_group_purchase, p_booking_id, p_amount_cents, v_currency,
    'succeeded', 'manual', p_method, p_method_note, p_reference,
    coalesce(p_description,
             case p_kind when 'plan' then v_plan_name
                         when 'dropin' then 'Drop-in class'
                         else 'Payment' end),
    coalesce(p_paid_at, now()), auth.uid(), v_list, v_promo, v_disc
  ) returning id into v_payment;

  return jsonb_build_object(
    'payment_id', v_payment,
    'membership_id', v_ms,
    'group_purchase_id', v_group_purchase,
    'booking_confirmed', v_confirmed,
    'renewed', v_renewal
  );
end $$;

-- schedule_post_data_run re-issued (20260833310000_decision93c_instructor_posts.sql:96): + needs per class (22 f).
create or replace function schedule_post_data_run(
  p_studio_id uuid, p_from date, p_to date,
  p_core_only boolean default false, p_instructor_id uuid default null
) returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_tz text; v_name text; v_logo text;
  v_fmt text; v_footer text; v_hash text; v_flexmin int;
  v_days jsonb;
  v_coach_first text; v_coach_photo text;
begin
  select timezone, name, logo_url into v_tz, v_name, v_logo
    from studios where id = p_studio_id;
  if v_tz is null then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;
  if p_to < p_from then
    raise exception 'that range ends before it starts' using errcode = 'PT400';
  end if;
  if p_to - p_from > 62 then
    raise exception 'ask for at most 62 days at a time' using errcode = 'PT422';
  end if;

  -- The coach, when one is chosen. Cross-studio is refused — a studio may only
  -- post its own instructors.
  if p_instructor_id is not null then
    select nullif(split_part(coalesce(display_name, ''), ' ', 1), ''), avatar_url
      into v_coach_first, v_coach_photo
      from instructors where id = p_instructor_id and studio_id = p_studio_id;
    if not found then
      raise exception 'that instructor is not in this studio' using errcode = 'PT403';
    end if;
  end if;

  select coalesce(time_format, '24h'),
         coalesce(post_footer_line, 'Book on the app'),
         post_hashtags,
         coalesce(flex_min_bookings, 1)
    into v_fmt, v_footer, v_hash, v_flexmin
    from studio_settings where studio_id = p_studio_id;
  v_fmt    := coalesce(v_fmt, '24h');
  v_footer := coalesce(v_footer, 'Book on the app');
  v_flexmin := coalesce(v_flexmin, 1);

  with occ as (
    select o.id, o.starts_at,
           (o.starts_at at time zone v_tz)::date as d,
           coalesce(nullif(o.name, ''), ct.name, 'Class') as cname,
           nullif(split_part(coalesce(i.display_name, ''), ' ', 1), '') as coach,
           coalesce(
             o.guarantee_tier,
             case when o.flex then 'flex'::guarantee_tier end,
             ser.guarantee_tier,
             case when ser.flex then 'flex'::guarantee_tier end,
             'core'::guarantee_tier)::text as tier,
           greatest(coalesce(o.capacity, 0) - occurrence_seats_taken(o.id), 0) as spots_left,
           -- Decision 22(f): how many more a flex class needs (null when it is
           -- not flex or is already running).
           (select case when (fs ->> 'flex')::boolean
                         and not (fs ->> 'reached_minimum')::boolean
                         and not (fs ->> 'committed')::boolean
                         and (fs ->> 'min_bookings')::int > (fs ->> 'paid_count')::int
                        then (fs ->> 'min_bookings')::int - (fs ->> 'paid_count')::int end
              from (select occurrence_flex_state_run(o.id) as fs) z) as needs
      from class_occurrences o
      left join class_series ser on ser.id = o.series_id
      left join class_types  ct  on ct.id  = o.class_type_id
      left join instructors  i   on i.id   = o.instructor_id
     where o.studio_id = p_studio_id
       and o.status = 'scheduled'
       and not o.hidden_from_members
       and (p_instructor_id is null or o.instructor_id = p_instructor_id)
       and (o.starts_at at time zone v_tz)::date between p_from and p_to
  ),
  filtered as (
    select * from occ where (not p_core_only) or tier = 'core'
  ),
  byday as (
    select d,
           count(*)::int as n,
           jsonb_agg(
             jsonb_build_object(
               'time',       fmt_clock(starts_at, v_tz, v_fmt),
               'name',       cname,
               'coach',      coach,
               'tier',       tier,
               'spots_left', spots_left,
               'needs',      needs
             ) order by starts_at, cname
           ) as classes
      from filtered
     group by d
  )
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'date',    to_char(d, 'YYYY-MM-DD'),
             'label',   to_char(d, 'FMDay FMDD Mon'),
             'count',   n,
             'classes', classes
           ) order by d), '[]'::jsonb)
    into v_days
    from byday;

  return jsonb_build_object(
    'studio_name', v_name,
    'logo_url',    v_logo,
    'time_zone',   v_tz,
    'time_format', v_fmt,
    'footer_line', v_footer,
    'hashtags',    v_hash,
    'flex_min',    v_flexmin,
    'coach_id',    p_instructor_id,
    'coach_first', v_coach_first,
    'coach_photo', v_coach_photo,
    'days',        v_days
  );
end $function$;
revoke execute on function schedule_post_data_run(uuid, date, date, boolean, uuid) from public, anon, authenticated;
grant  execute on function schedule_post_data_run(uuid, date, date, boolean, uuid) to service_role;

-- ===========================================================================
-- Anon stays EXACTLY FOURTEEN; the new readers are not anon.
-- ===========================================================================
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect\_%' and p.proname not in ('call_jsonb');
  if n <> 14 then raise exception 'anon surface is %, expected 14', n; end if;
  if has_function_privilege('anon', 'member_flex_states(uuid, timestamptz, timestamptz, uuid)', 'execute')
     or has_function_privilege('anon', 'core_classes_for_rescue(uuid, uuid)', 'execute') then
    raise exception 'a Step 12b reader is anon-callable';
  end if;
end $$;
