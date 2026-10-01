-- =============================================================================
-- Decision 42b — bulk changes on recurring classes.
-- =============================================================================
-- A manager selects any number of series on the Recurring-classes list and
-- applies ONE change to all of them. The apply goes through the SAME
-- single-series functions the series page uses, one series at a time, each in
-- its own subtransaction (a savepoint, so one refusal never aborts the batch),
-- so every existing rule, warning and refusal applies unchanged — no new
-- propagation rule is invented here.
--
-- change types (p_change is exactly ONE family):
--   {minimum:int}                 -> set_series_guarantee(id, CURRENT tier, min)
--   {tier:core|flex|always, minimum:int|null}
--                                 -> set_series_guarantee(id, tier, min)
--   {room_id:uuid}                -> update_series(..., room=NEW, confirm) — re-rooms
--                                    future occurrences exactly as the page does;
--                                    a room clash on any occurrence refuses that
--                                    series (its savepoint is rolled back) and it
--                                    is listed.
--   {ends_on:date|null}           -> update_series(..., ends_on=NEW) — removes
--                                    future occurrences beyond it; booked ones
--                                    booked -> refused + listed.
--   {starts_on:date}              -> update_series(..., starts_on=NEW) — a change
--                                    that would drop booked earlier occurrences is
--                                    refused + listed.
--   {instructor_id:uuid|null}     -> a DIRECT class_series.instructor_id write,
--                                    template-only (Decisions 42a/43): a seed for
--                                    future materialisation, never touching an
--                                    existing occurrence. update_series would
--                                    reassign occurrences, so it is NOT used here.
--
-- free_first_allowed (the Decision 30 amendment's class_series column) does NOT
-- exist yet, so the seventh change type is deliberately NOT added.
--
-- Preview runs the REAL function inside the savepoint and rolls it back, so the
-- rules can never drift from a second implementation.
--
-- creates: bulk_update_series_run(uuid[], jsonb, boolean),
--   bulk_update_series(uuid[], jsonb, boolean)
-- =============================================================================

create function bulk_update_series_run(
  p_series_ids uuid[], p_change jsonb, p_preview boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_studio uuid; v_type text; v_have int; v_cnt int;
  rec record; ser class_series%rowtype;
  v_res jsonb; v_bad boolean; v_reason text;
  v_cur text; v_new text; v_when text; v_day text;
  v_changed jsonb := '[]'::jsonb;
  v_refused jsonb := '[]'::jsonb;
  v_warn    jsonb := '[]'::jsonb;
  v_n_changed int := 0; v_n_refused int := 0;
  r_name text;
begin
  if p_series_ids is null or array_length(p_series_ids, 1) is null then
    raise exception 'select at least one series' using errcode = 'PT422';
  end if;

  -- One studio, every id present, and the caller manages it. A foreign or
  -- unknown id anywhere -> PT403 (never act on a partial, mixed-studio set).
  select count(distinct studio_id), (array_agg(distinct studio_id))[1] into v_cnt, v_studio
    from class_series where id = any(p_series_ids);
  if v_cnt <> 1 then
    raise exception 'those series are not all in one studio you manage' using errcode = 'PT403';
  end if;
  if not coalesce(is_manager_up(v_studio), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  select count(*) into v_have from class_series
   where studio_id = v_studio and id = any(p_series_ids);
  if v_have <> (select count(distinct x) from unnest(p_series_ids) x) then
    raise exception 'those series are not all in one studio you manage' using errcode = 'PT403';
  end if;

  -- Which single change family.
  v_type := case
    when p_change ? 'tier'          then 'tier'
    when p_change ? 'room_id'       then 'room'
    when p_change ? 'ends_on'       then 'ends_on'
    when p_change ? 'starts_on'     then 'starts_on'
    when p_change ? 'instructor_id' then 'instructor'
    when p_change ? 'minimum'       then 'minimum'
    else null end;
  if v_type is null then
    raise exception 'that is not a change this can apply' using errcode = 'PT422';
  end if;

  for rec in
    select cs.id from class_series cs
     where cs.id = any(p_series_ids)
     order by cs.name, cs.time_of_day
  loop
    select * into ser from class_series where id = rec.id;
    r_name := ser.name;

    -- "Mon 07:00": the first BYDAY of the rule plus the time. Built in SQL so the
    -- refusal sentence the UI renders carries the database's own label.
    v_day := substring(ser.rrule from 'BYDAY=([A-Z]{2})');
    v_when := trim(coalesce(
      case v_day when 'MO' then 'Mon' when 'TU' then 'Tue' when 'WE' then 'Wed'
                 when 'TH' then 'Thu' when 'FR' then 'Fri' when 'SA' then 'Sat'
                 when 'SU' then 'Sun' else '' end, '')
      || ' ' || to_char(ser.time_of_day, 'HH24:MI'));

    -- current -> new, for the preview table.
    if v_type = 'minimum' then
      v_cur := 'min ' || coalesce((case ser.guarantee_tier
                 when 'flex' then ser.minimum_bookings
                 when 'core' then ser.core_min_bookings else null end)::text, '—');
      v_new := 'min ' || (p_change ->> 'minimum');
    elsif v_type = 'tier' then
      v_cur := ser.guarantee_tier::text;
      v_new := (p_change ->> 'tier')
               || case when nullif(p_change ->> 'minimum','') is not null
                       then ' · min ' || (p_change ->> 'minimum') else '' end;
    elsif v_type = 'room' then
      v_cur := coalesce((select name from rooms where id = ser.room_id), 'no room');
      v_new := coalesce((select name from rooms where id = (p_change ->> 'room_id')::uuid), 'no room');
    elsif v_type = 'ends_on' then
      v_cur := coalesce(ser.ends_on::text, 'no end');
      v_new := coalesce(nullif(p_change ->> 'ends_on','')::date::text, 'no end');
    elsif v_type = 'starts_on' then
      v_cur := ser.starts_on::text;
      v_new := (p_change ->> 'starts_on');
    else  -- instructor
      v_cur := coalesce((select display_name from instructors where id = ser.instructor_id), 'Unassigned');
      v_new := coalesce((select display_name from instructors where id = nullif(p_change ->> 'instructor_id','')::uuid), 'Unassigned');
    end if;

    v_res := null;
    begin   -- SAVEPOINT per series
      if v_type = 'minimum' then
        v_res := set_series_guarantee(rec.id, ser.guarantee_tier, (p_change ->> 'minimum')::int, null);
      elsif v_type = 'tier' then
        v_res := set_series_guarantee(rec.id, (p_change ->> 'tier')::guarantee_tier,
                                      nullif(p_change ->> 'minimum','')::int, null);
      elsif v_type = 'room' then
        v_res := update_series(rec.id, ser.name, ser.class_type_id, (p_change ->> 'room_id')::uuid,
                   ser.instructor_id, ser.capacity, ser.duration_minutes, ser.rrule,
                   ser.starts_on, ser.ends_on, ser.time_of_day, ser.description, null, true);
      elsif v_type = 'ends_on' then
        v_res := update_series(rec.id, ser.name, ser.class_type_id, ser.room_id,
                   ser.instructor_id, ser.capacity, ser.duration_minutes, ser.rrule,
                   ser.starts_on, nullif(p_change ->> 'ends_on','')::date, ser.time_of_day,
                   ser.description, null, true);
      elsif v_type = 'starts_on' then
        v_res := update_series(rec.id, ser.name, ser.class_type_id, ser.room_id,
                   ser.instructor_id, ser.capacity, ser.duration_minutes, ser.rrule,
                   (p_change ->> 'starts_on')::date, ser.ends_on, ser.time_of_day,
                   ser.description, null, true);
      else  -- instructor: template only, zero occurrences touched (42a/43).
        -- instructor_id is a materialise-trigger column, so suppress the trigger
        -- (series_editing) — the write must touch no occurrence, not generate.
        perform set_config('studiior.series_editing', 'on', true);
        update class_series set instructor_id = nullif(p_change ->> 'instructor_id','')::uuid,
               updated_at = now() where id = rec.id;
        perform set_config('studiior.series_editing', 'off', true);
        v_res := jsonb_build_object('ok', true);
      end if;

      -- Refused: the function said no, or (a room change) left a per-occurrence
      -- clash — all-or-nothing per series in a batch, so the whole series rolls
      -- back and is listed.
      v_bad := (not coalesce((v_res ->> 'ok')::boolean, true))
            or (jsonb_array_length(coalesce(v_res -> 'conflicts', '[]'::jsonb)) > 0);

      if p_preview or v_bad then
        raise exception 'discard' using errcode = 'PT000';
      end if;

      -- Apply, kept.
      v_changed := v_changed || jsonb_build_object('series_id', rec.id, 'name', r_name,
                     'when', v_when, 'current', v_cur, 'new', v_new);
      v_n_changed := v_n_changed + 1;
      if coalesce((v_res ->> 'standalone_count')::int, 0) > 0 then
        v_warn := v_warn || jsonb_build_object('series_id', rec.id, 'code', 'standalone_flex');
      end if;

    exception
      when sqlstate 'PT000' then
        -- Our own forced rollback. v_res holds what the function returned.
        if (not coalesce((v_res ->> 'ok')::boolean, true))
           or (jsonb_array_length(coalesce(v_res -> 'conflicts', '[]'::jsonb)) > 0) then
          v_reason := case
            when jsonb_array_length(coalesce(v_res -> 'conflicts', '[]'::jsonb)) > 0
                 then 'the room is taken on some of its classes'
            when (v_res ->> 'reason') = 'members_booked_on_dropped_classes' and v_type = 'starts_on'
                 then 'earlier classes have bookings'
            when (v_res ->> 'reason') = 'members_booked_on_dropped_classes'
                 then 'later classes have bookings'
            else coalesce(v_res ->> 'reason', 'refused') end;
          v_refused := v_refused || jsonb_build_object('series_id', rec.id, 'name', r_name,
                         'when', v_when, 'reason', v_reason);
          v_n_refused := v_n_refused + 1;
        else
          -- Preview: this one WOULD change (nothing kept).
          v_changed := v_changed || jsonb_build_object('series_id', rec.id, 'name', r_name,
                         'when', v_when, 'current', v_cur, 'new', v_new);
          v_n_changed := v_n_changed + 1;
          if coalesce((v_res ->> 'standalone_count')::int, 0) > 0 then
            v_warn := v_warn || jsonb_build_object('series_id', rec.id, 'code', 'standalone_flex');
          end if;
        end if;
      when others then
        -- The single-series function itself raised (bad input, locked studio …).
        v_reason := case
          when sqlstate = 'PT402' then 'this studio''s subscription is not active'
          when sqlstate = 'PT422' then 'that change is not allowed for this series'
          else coalesce(sqlerrm, 'refused') end;
        v_refused := v_refused || jsonb_build_object('series_id', rec.id, 'name', r_name,
                       'when', v_when, 'reason', v_reason);
        v_n_refused := v_n_refused + 1;
    end;
  end loop;

  -- One batch audit line on apply (the single-series functions write their own
  -- rows; this records the batch and its counts).
  if not p_preview then
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (v_studio, auth.uid(), 'series.bulk_updated', 'class_series', v_studio,
            jsonb_build_object('change', p_change, 'change_type', v_type,
                               'changed', v_n_changed, 'refused', v_n_refused,
                               'series', p_series_ids));
  end if;

  return jsonb_build_object('ok', true, 'preview', p_preview, 'change_type', v_type,
                            'changed', v_changed, 'refused', v_refused, 'warnings', v_warn);
end $$;

-- The manager-up wrapper. The studio guard lives in _run (it resolves the studio
-- from the set), so the wrapper is a thin delegate; both are kept so the house
-- pattern (client calls the wrapper, internals call the _run) holds.
create function bulk_update_series(
  p_series_ids uuid[], p_change jsonb, p_preview boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  return bulk_update_series_run(p_series_ids, p_change, p_preview);
end $$;

revoke execute on function bulk_update_series_run(uuid[], jsonb, boolean) from public, anon, authenticated;
grant  execute on function bulk_update_series_run(uuid[], jsonb, boolean) to service_role;
revoke execute on function bulk_update_series(uuid[], jsonb, boolean) from public, anon;
grant  execute on function bulk_update_series(uuid[], jsonb, boolean) to authenticated, service_role;

-- Anon surface unchanged — exactly TWELVE.
do $$
declare v_anon int;
begin
  select count(*) into v_anon
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not in ('expect_num','expect_text','expect_true','expect_false','login','sig','psig');
  if v_anon <> 12 then
    raise exception 'anon surface is % functions, expected exactly 12', v_anon;
  end if;
end $$;
