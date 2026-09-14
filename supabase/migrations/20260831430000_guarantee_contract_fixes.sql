-- =============================================================================
-- 138  The guarantee contract: core commit notice, flat slot-holding fee,
--      post-commitment reassurance, and a standalone-flex warning.
-- =============================================================================
-- Reform Collective's instructor agreement, cross-checked against Decision 22.
-- Four gaps, all PER TENANT (a studio with guarantees off sees none of this):
--
--   A  a FLAT slot-holding fee beside the percentage. "Pay 400 regardless"
--      cannot be a percentage of a rate that changes; 50% of 900 is 450, not
--      400. Flat wins where set; the percentage stays the fallback so a studio
--      that only ever set a pct is untouched.
--   C  the CORE early latch + notice. The guarantee has to FEEL real from the
--      first booking, which is the moment it becomes committed. Mirrors flex's
--      flex_reached_minimum_at EXACTLY as a notification — and, unlike flex,
--      does NOT extend evaluate_commitment: a core class empty at the cutoff is
--      not_running and pays the slot-holding fee (the contract's own pay
--      table), so committing it early would overpay and mislabel. The snapshot
--      (booked_at_cutoff) and the terminal commit (committed_at) stay at the
--      cutoff, untouched.
--   B  post-commitment reassurance. A member cancelling a COMMITTED class does
--      not change instructor pay (fixed from the cutoff snapshot); an
--      instructor not told will ask, every time.
--   D  a standalone-flex WARNING in the editor. A flex slot with nothing of the
--      instructor's beside it is a standby-fee obligation; set_series_flex now
--      returns the count so the editor stops creating it silently.
--
-- instructor_no_show is NOT added as a cancellation cause: Decision 28's
-- held-until-confirmed check-in is how a no-show is represented, and a fourth
-- cause would let a class read instructor_no_show while its pay record sits
-- confirmed — the two disagreeing. See docs/STUDIIOR_V1_DECISIONS.md.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A. The flat slot-holding fee (per studio; null = use the percentage)
-- -----------------------------------------------------------------------------
alter table studio_settings
  add column if not exists core_unmet_pay_cents int;

comment on column studio_settings.core_unmet_pay_cents is
  'A FLAT slot-holding fee for a core class that does not run. When set it wins '
  'over core_unmet_pay_pct (a percentage of base); null keeps the percentage. '
  'Per tenant. Reform Collective: a flat amount; other studios a percentage.';

-- The calculation is compute_class_pay_run (migration 096 renamed it behind a
-- guarded wrapper). Re-issued from its body with ONE change: the group core
-- not_running branch prefers the flat fee. Everything else is byte-for-byte the
-- migration-082 calculation. create-or-replace keeps its ACL.
create or replace function compute_class_pay_run(p_occurrence_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  o class_occurrences%rowtype; s studio_settings%rowtype; g record;
  rv instructor_rate_versions%rowtype; v_kind session_kind; v_tz text;
  v_local date; v_amount int; v_basis jsonb; v_heads int; v_flat int;
begin
  select * into o from class_occurrences where id = p_occurrence_id;
  if not found then raise exception 'no such class' using errcode = 'PT404'; end if;
  if o.instructor_id is null then
    return jsonb_build_object('ok', false, 'reason', 'no instructor on this class');
  end if;

  select * into s from studio_settings where studio_id = o.studio_id;
  select timezone into v_tz from studios where id = o.studio_id;
  v_local := (o.starts_at at time zone v_tz)::date;

  -- The version in force ON THE DAY OF THE CLASS, not today. This is what makes
  -- a rate change next month leave last month alone.
  select * into rv from instructor_rate_at(o.instructor_id, v_local);
  if rv.id is null then
    return jsonb_build_object('ok', false, 'reason', 'no rate on file for that date');
  end if;

  select coalesce(ct.session_kind, 'group') into v_kind
    from class_types ct where ct.id = o.class_type_id;
  v_kind := coalesce(v_kind, 'group');

  select * into g from occurrence_guarantee(p_occurrence_id);
  v_heads := coalesce(o.booked_at_cutoff, 0);

  -- 1. A private, duo or trio REPLACES the whole calculation. Flat, by product.
  if v_kind <> 'group' then
    v_flat := case v_kind
      when 'private' then rv.private_rate_cents
      when 'duo'     then rv.duo_rate_cents
      else                rv.trio_rate_cents end;
    if v_flat is null then
      return jsonb_build_object('ok', false,
        'reason', format('no %s rate on file', v_kind));
    end if;
    -- A private that did not run follows the same cancellation rules as any
    -- other class, against its flat rate rather than a base.
    if o.status = 'cancelled' then
      v_amount := case o.cancellation_cause
        when 'unmet_minimum' then
          case when g.tier = 'flex' then coalesce(s.flex_unmet_pay_cents, 0)
               else (v_flat * coalesce(s.core_unmet_pay_pct, 0)) / 100 end
        when 'studio_fault'  then v_flat
        when 'force_majeure' then 0
        when 'closure'       then case when coalesce(o.cancellation_pays, false) then v_flat else 0 end
        else 0 end;
    else
      v_amount := v_flat;
    end if;
    v_basis := jsonb_build_object('kind', v_kind, 'flat_rate_cents', v_flat,
                                  'status', o.status, 'cause', o.cancellation_cause);

  -- 2. It ran, or it is committed and therefore owed in full whatever happened
  --    afterwards.
  elsif o.status <> 'cancelled' or o.committed_at is not null then
    v_amount := rv.base_rate_cents
              + greatest(0, v_heads - rv.per_head_threshold) * rv.per_head_rate_cents
              -- Keys off THE CLASS's capacity, which varies by room. A capacity
              -- 5 studio and a capacity 6 studio both reach a full house.
              + case when o.capacity is not null and v_heads >= o.capacity
                     then rv.full_house_bonus_cents else 0 end;
    v_basis := jsonb_build_object(
      'kind', 'group', 'base_cents', rv.base_rate_cents,
      'booked_at_cutoff', v_heads, 'capacity', o.capacity,
      'per_head_cents', rv.per_head_rate_cents, 'per_head_threshold', rv.per_head_threshold,
      'heads_paid', greatest(0, v_heads - rv.per_head_threshold),
      'full_house', (o.capacity is not null and v_heads >= o.capacity),
      'full_house_bonus_cents', case when o.capacity is not null and v_heads >= o.capacity
                                     then rv.full_house_bonus_cents else 0 end);

  -- 3. It is not running.
  else
    if o.cancellation_cause = 'unmet_minimum' then
      if g.tier = 'flex' then
        -- Standby is paid when the slot was STANDALONE. A flex class next to
        -- another of the instructor's classes costs them nothing extra; one on
        -- its own cost them the trip. Both settings default to 0, so a studio
        -- that has not set them is unaffected either way.
        v_amount := coalesce(s.flex_unmet_pay_cents, 0)
                  + case when occurrence_is_adjacent(p_occurrence_id)
                         then 0 else coalesce(s.flex_standby_pay_cents, 0) end;
        v_basis := jsonb_build_object('kind', 'group', 'outcome', 'not_running',
          'tier', 'flex', 'unmet_pay_cents', coalesce(s.flex_unmet_pay_cents, 0),
          'standby_cents', case when occurrence_is_adjacent(p_occurrence_id)
                                then 0 else coalesce(s.flex_standby_pay_cents, 0) end,
          'adjacent', occurrence_is_adjacent(p_occurrence_id));
      else
        -- The slot-holding fee: a FLAT amount when the studio set one
        -- (core_unmet_pay_cents), otherwise the percentage of base. Flat wins
        -- because "pay 400 regardless" cannot be a percentage of a rate that
        -- changes; the percentage stays the fallback so existing studios that
        -- only ever set a pct are untouched.
        v_amount := coalesce(s.core_unmet_pay_cents,
                             (rv.base_rate_cents * coalesce(s.core_unmet_pay_pct, 0)) / 100);
        v_basis := jsonb_build_object('kind', 'group', 'outcome', 'not_running',
          'tier', 'core', 'base_cents', rv.base_rate_cents,
          'holding_model', case when s.core_unmet_pay_cents is not null then 'flat' else 'pct' end,
          'holding_flat_cents', s.core_unmet_pay_cents,
          'holding_pct', coalesce(s.core_unmet_pay_pct, 0));
      end if;
    else
      v_amount := case o.cancellation_cause
        when 'studio_fault'  then rv.base_rate_cents
        when 'force_majeure' then 0
        when 'closure' then case when coalesce(o.cancellation_pays, false)
                                 then rv.base_rate_cents else 0 end
        else 0 end;
      v_basis := jsonb_build_object('kind', 'group', 'outcome', 'cancelled',
        'cause', o.cancellation_cause, 'base_cents', rv.base_rate_cents,
        'closure_pays', o.cancellation_pays);
    end if;
  end if;

  return jsonb_build_object('ok', true, 'amount_cents', v_amount,
    'currency', rv.currency, 'rate_version_id', rv.id,
    'instructor_id', o.instructor_id, 'local_date', v_local, 'basis', v_basis);
end $$;

-- -----------------------------------------------------------------------------
-- C. The core early latch — notification only
-- -----------------------------------------------------------------------------
alter table class_occurrences
  add column if not exists core_reached_minimum_at timestamptz;

comment on column class_occurrences.core_reached_minimum_at is
  'When a CORE class first reached its minimum booking and the instructor was '
  'told it is committed. Mirrors flex_reached_minimum_at, but NOTIFICATION '
  'ONLY: evaluate_commitment does not read it, so the snapshot and the terminal '
  'commit stay at the cutoff. A core class empty at the cutoff is still '
  'not_running (slot-holding fee), per the contract.';

insert into notification_templates (key, subject, text_body, html_body, note) values
('core_committed',
 '{class_name} is committed',
 E'Hi {instructor_name},\n\n{class_name} on {when} has its first booking — it is committed. {booked_line}\n\nWe will not drop it for low bookings. You are paid from the headcount at the booking cutoff: in full if anyone is booked then, the slot-holding fee if not.\n\nSee you there,\n{studio_name}',
 '<p>Hi {instructor_name},</p><p><strong>{class_name}</strong> on {when} has its first booking — it is committed. {booked_line}</p><p>We will not drop it for low bookings. You are paid from the headcount at the booking cutoff: in full if anyone is booked then, the slot-holding fee if not.</p><p>See you there,<br>{studio_name}</p>',
 'The core early latch (contract). Fires when a core class first reaches its minimum booking — mirrors flex_going_ahead. Notification only.')
on conflict (key) do update
  set subject = excluded.subject, text_body = excluded.text_body,
      html_body = excluded.html_body, note = excluded.note;

create function tg_core_reached_minimum() returns trigger
language plpgsql security definer set search_path = public as $fn$
declare g record; s studios%rowtype; v_user uuid; v_name text;
begin
  -- Cheap exits: only a scheduled, uncommitted, not-yet-latched class with an
  -- instructor to tell is a candidate. (No flex check: a class is core or flex,
  -- and the tier gate below decides.)
  if new.status <> 'scheduled'
     or new.committed_at is not null
     or new.core_reached_minimum_at is not null
     or new.instructor_id is null then
    return new;
  end if;

  select * into g from occurrence_guarantee_run(new.id) g;
  -- Only a class that BEHAVES as core (guarantees switch on) has a minimum to
  -- reach; occurrence_guarantee demotes a core class at a guarantees-off studio
  -- to 'always', correctly ignored here.
  if g.tier is distinct from 'core' or g.minimum is null or new.booked_count < g.minimum then
    return new;
  end if;

  update class_occurrences set core_reached_minimum_at = now()
   where id = new.id and core_reached_minimum_at is null;

  select * into s from studios where id = new.studio_id;
  v_user := instructor_user_id(new.instructor_id);
  if v_user is not null then
    select display_name into v_name from instructors where id = new.instructor_id;
    perform queue_shift_notice(new.studio_id, v_user, 'core_committed',
      jsonb_build_object(
        'instructor_name', coalesce(v_name, 'there'),
        'studio_name', s.name,
        'class_name', new.name,
        'when', to_char(new.starts_at at time zone s.timezone, 'FMDay FMDD FMMon, HH24:MI'),
        'booked_line', case when new.booked_count = 1 then '1 booked.'
                            else new.booked_count || ' booked.' end),
      -- Once per class per instructor per start time — a reassignment after a
      -- move is a different person to reassure.
      'core_committed:' || new.id || ':' || new.instructor_id
        || ':' || extract(epoch from new.starts_at)::bigint);
  end if;
  return new;
end $fn$;

create trigger tg_core_reached_minimum
  after update of booked_count on class_occurrences
  for each row execute function tg_core_reached_minimum();

revoke execute on function tg_core_reached_minimum() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- B. Post-commitment reassurance
-- -----------------------------------------------------------------------------
insert into notification_templates (key, subject, text_body, html_body, note) values
('booking_cancelled_committed',
 'A member cancelled {class_name} — it still runs',
 E'Hi {instructor_name},\n\nA member cancelled your {class_name} on {when}. It still runs and your pay is unchanged at {amount}.\n\nNothing for you to do.\n\n{studio_name}',
 '<p>Hi {instructor_name},</p><p>A member cancelled your <strong>{class_name}</strong> on {when}. It still runs and your pay is unchanged at {amount}.</p><p>Nothing for you to do.</p><p>{studio_name}</p>',
 'Post-commitment reassurance (contract). A member cancelling a COMMITTED class does not change instructor pay (fixed from the cutoff snapshot).')
on conflict (key) do update
  set subject = excluded.subject, text_body = excluded.text_body,
      html_body = excluded.html_body, note = excluded.note;

create function tg_notify_committed_cancel() returns trigger
language plpgsql security definer set search_path = public as $fn$
declare o class_occurrences%rowtype; s studios%rowtype; v_user uuid; v_name text;
  v_pay jsonb; v_amount text;
begin
  -- A confirmed member seat cancelling (booked -> cancelled/late). Not the
  -- studio-release path (that cancels the whole class — a different message),
  -- caught both by the releasing flag and by the occurrence no longer being
  -- scheduled below.
  if not (old.status = 'booked' and new.status in ('cancelled','late_cancelled')) then
    return new;
  end if;
  if coalesce(current_setting('studiior.releasing', true), '') = '1' then
    return new;
  end if;

  select * into o from class_occurrences where id = new.occurrence_id;
  -- Only a COMMITTED, still-scheduled class. committed_at is terminal and means
  -- pay is already fixed from the cutoff snapshot, so "unchanged" is true.
  if o.committed_at is null or o.status <> 'scheduled' or o.instructor_id is null then
    return new;
  end if;

  v_user := instructor_user_id(o.instructor_id);
  if v_user is null then return new; end if;

  v_pay := compute_class_pay_run(o.id);
  if not coalesce((v_pay ->> 'ok')::boolean, false) then return new; end if;

  select * into s from studios where id = o.studio_id;
  select display_name into v_name from instructors where id = o.instructor_id;
  v_amount := dashboard_money_text((v_pay ->> 'amount_cents')::bigint, v_pay ->> 'currency');

  perform queue_shift_notice(o.studio_id, v_user, 'booking_cancelled_committed',
    jsonb_build_object(
      'instructor_name', coalesce(v_name, 'there'),
      'studio_name', s.name,
      'class_name', o.name,
      'when', to_char(o.starts_at at time zone s.timezone, 'FMDay FMDD FMMon, HH24:MI'),
      'amount', v_amount),
    'booking_cancelled_committed:' || new.id);
  return new;
end $fn$;

create trigger tg_notify_committed_cancel
  after update of status on bookings
  for each row execute function tg_notify_committed_cancel();

revoke execute on function tg_notify_committed_cancel() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- D. Standalone-flex warning in the editor
-- -----------------------------------------------------------------------------
create or replace function set_series_flex(p_series_id uuid, p_flex boolean, p_minimum_bookings integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare ser class_series%rowtype; v_min int; n int; n_standalone int := 0;
begin
  select * into ser from class_series where id = p_series_id;
  if not found then
    raise exception 'no such series' using errcode = 'PT404';
  end if;
  if not coalesce(is_manager_up(ser.studio_id), false) then
    raise exception 'only owners and managers change the timetable' using errcode = 'PT403';
  end if;
  if p_flex and coalesce(p_minimum_bookings, 0) < 1 then
    raise exception 'a flex class needs a minimum of at least one booking'
      using errcode = 'PT422';
  end if;
  v_min := case when p_flex then p_minimum_bookings else null end;

  update class_series set flex = p_flex, minimum_bookings = v_min, updated_at = now()
   where id = p_series_id;

  with touched as (
    update class_occurrences
       set flex = p_flex, minimum_bookings = v_min, updated_at = now()
     where series_id = p_series_id
       and status = 'scheduled'
       and starts_at > now()
       and committed_at is null
    returning 1)
  select count(*) into n from touched;

  -- STANDALONE = a flex slot with no other class of the same instructor beside
  -- it on the day: the one that costs a trip for a class that may not run, and
  -- so a standby-fee obligation under the instructor agreement. Surfaced so the
  -- editor can warn rather than create it silently. Adjacency is dynamic (a
  -- later move can change it), so this is a WARNING count, never a refusal.
  if p_flex then
    select count(*) into n_standalone
      from class_occurrences o
     where o.series_id = p_series_id
       and o.status = 'scheduled'
       and o.starts_at > now()
       and coalesce(o.flex, false)
       and not occurrence_is_adjacent_run(o.id);
  end if;

  return jsonb_build_object('ok', true, 'flex', p_flex,
                            'minimum_bookings', v_min, 'occurrences_updated', n,
                            'standalone_count', n_standalone);
end $function$;

-- set_series_guarantee is what the tier control actually calls (set_series_flex
-- is the lower-level Decision-21 writer). Re-issued from migration 098 with the
-- same standalone count so the editor can warn when turning a series flex.
create or replace function set_series_guarantee(p_series_id uuid, p_tier guarantee_tier, p_min_bookings integer DEFAULT NULL::integer, p_core_cutoff_hours integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare ser class_series%rowtype; n int; n_standalone int := 0;
begin
  select * into ser from class_series where id = p_series_id;
  if not found then raise exception 'no such series' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(ser.studio_id), false) then
    raise exception 'only owners and managers set a guarantee' using errcode = 'PT403';
  end if;
  if p_min_bookings is not null and p_min_bookings < 0 then
    raise exception 'a minimum cannot be negative' using errcode = 'PT422';
  end if;

  update class_series
     set guarantee_tier   = p_tier,
         flex             = (p_tier = 'flex'),
         minimum_bookings = case when p_tier = 'flex'
                                 then coalesce(p_min_bookings, minimum_bookings)
                                 else minimum_bookings end,
         core_min_bookings = case when p_tier = 'core'
                                  then coalesce(p_min_bookings, core_min_bookings)
                                  else core_min_bookings end,
         core_cutoff_hours = coalesce(p_core_cutoff_hours, core_cutoff_hours),
         updated_at = now()
   where id = p_series_id;

  update class_occurrences o
     set guarantee_tier = p_tier,
         flex           = (p_tier = 'flex'),
         minimum_bookings = case when p_tier = 'flex'
                                 then coalesce(p_min_bookings, o.minimum_bookings)
                                 else o.minimum_bookings end,
         core_min_bookings = case when p_tier = 'core'
                                  then coalesce(p_min_bookings, o.core_min_bookings)
                                  else o.core_min_bookings end,
         updated_at = now()
   where o.series_id = p_series_id
     and o.starts_at > now()
     and o.status = 'scheduled'
     and o.committed_at is null;
  get diagnostics n = row_count;

  -- A standalone flex slot (nothing of the instructor's beside it) is a
  -- standby-fee obligation. Reported so the editor warns rather than creating
  -- one silently; a warning, never a refusal (adjacency is dynamic).
  if p_tier = 'flex' then
    select count(*) into n_standalone
      from class_occurrences o
     where o.series_id = p_series_id
       and o.status = 'scheduled'
       and o.starts_at > now()
       and coalesce(o.flex, false)
       and not occurrence_is_adjacent_run(o.id);
  end if;

  return jsonb_build_object('ok', true, 'tier', p_tier, 'occurrences_updated', n,
                            'standalone_count', n_standalone);
end $function$;
