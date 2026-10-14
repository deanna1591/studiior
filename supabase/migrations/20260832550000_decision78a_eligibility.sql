-- Decision 78a — a no-show gets ONE more free class, and book_first_free reuses
-- the once-ever ledger row so the second attempt does not collide with the
-- guest_passes_one_per_email unique index.
--
-- re-issues: free_first_eligibility(uuid, uuid), book_first_free(uuid)
--
-- free_first_eligibility (from 20260831630000) now distinguishes a member whose
-- only free-class booking is a no_show (comp, no attended free class, no
-- membership ever) — eligible once more — from one who attended, converted, or
-- no-showed twice ('missed_twice'). The attempt count comes from the member's
-- comp no_show BOOKINGS, not the guest_passes rows, because the ledger row is
-- reused on rebook (the once-ever index is untouched, its hard guarantee intact).
--
-- book_first_free (from 20260832120000) is byte-for-byte EXCEPT its guest_passes
-- INSERT becomes an upsert on the once-ever index, so a no-show member's rebook
-- updates the single ledger row to the new occurrence/booking instead of raising
-- 23505.

create or replace function free_first_eligibility(p_studio_id uuid, p_member_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_member members%rowtype;
  v_has_hostnull  boolean;
  v_noshow        int;
  v_comp_attended int;
  v_comp_live     int;
  v_other_qual    int;
  v_has_membership boolean;
begin
  select * into v_member from members where id = p_member_id;
  if not found or v_member.studio_id <> p_studio_id then
    raise exception 'no such member here' using errcode = 'PT404';
  end if;
  -- Self, desk-up, or a background job. Takes an id, returns member-shaped data
  -- (migration 056): the grant is not the guard.
  if not (coalesce(v_member.user_id = auth.uid(), false)
          or coalesce(is_desk_up(p_studio_id), false)
          or is_service_context()) then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;

  if not coalesce((select free_first_class_enabled from studio_settings
                    where studio_id = p_studio_id), false) then
    return jsonb_build_object('ok', false, 'reason', 'not_enabled');
  end if;

  -- Already a member here under an email VARIANT (same normalized key, a
  -- different member row). Decision 30 is for NEW members.
  if exists (select 1 from members
              where studio_id = p_studio_id and id <> p_member_id
                and normalize_email_key(email) = normalize_email_key(v_member.email)) then
    return jsonb_build_object('ok', false, 'reason', 'already_member');
  end if;

  -- The GUEST door (Decision 26): a host-not-null pass on the once-ever key means
  -- they had their free class as someone's guest — done, whatever the booking did.
  if exists (select 1 from guest_passes
              where studio_id = p_studio_id and host_member_id is not null
                and normalize_email_key(guest_email) = normalize_email_key(v_member.email)) then
    return jsonb_build_object('ok', false, 'reason', 'already_had_free');
  end if;

  -- The free-first (signup) door: a host-null pass on the key.
  v_has_hostnull := exists (select 1 from guest_passes
              where studio_id = p_studio_id and host_member_id is null
                and normalize_email_key(guest_email) = normalize_email_key(v_member.email));

  if v_has_hostnull then
    -- Decision 78: a no-show gets ONE more chance. Count the member's OWN free
    -- attempts by the comp bookings they produced (the ledger row is reused on
    -- rebook, so it is never the counter). Attended-a-free-class or holds-any-
    -- membership means they had it / converted; a live comp seat means a free
    -- class is pending; any non-comp class means they are no longer a first-timer.
    select
      count(*) filter (where b.payment_source = 'comp' and b.status = 'no_show'),
      count(*) filter (where b.payment_source = 'comp' and b.status = 'attended'),
      count(*) filter (where b.payment_source = 'comp' and b.status in ('booked','waitlisted','pending_payment')),
      count(*) filter (where b.payment_source <> 'comp' and b.status in ('booked','waitlisted','attended','no_show','pending_payment'))
      into v_noshow, v_comp_attended, v_comp_live, v_other_qual
      from bookings b
     where b.member_id = p_member_id and b.studio_id = p_studio_id;
    v_has_membership := exists (select 1 from memberships ms where ms.member_id = p_member_id);

    if v_comp_attended > 0 or v_has_membership or v_comp_live > 0 or v_other_qual > 0 then
      return jsonb_build_object('ok', false, 'reason', 'already_had_free');
    elsif v_noshow >= 2 then
      return jsonb_build_object('ok', false, 'reason', 'missed_twice');
    elsif v_noshow >= 1 then
      return jsonb_build_object('ok', true);   -- a no-show, once more
    else
      return jsonb_build_object('ok', false, 'reason', 'already_had_free');
    end if;
  end if;

  -- No free attempt yet. An ordinary not-first-timer check — a comp no_show
  -- cannot reach here (it implies a host-null pass), so this is unchanged.
  if exists (select 1 from bookings
              where member_id = p_member_id and studio_id = p_studio_id
                and status in ('booked','waitlisted','attended','no_show','pending_payment')) then
    return jsonb_build_object('ok', false, 'reason', 'not_first');
  end if;

  return jsonb_build_object('ok', true);
end $$;
revoke execute on function free_first_eligibility(uuid, uuid) from public, anon;
grant  execute on function free_first_eligibility(uuid, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.book_first_free(p_occurrence_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_occ    class_occurrences%rowtype;
  v_member members%rowtype;
  v_set    studio_settings%rowtype;
  v_ser    class_series%rowtype;
  v_cfg_tier guarantee_tier;
  v_tz     text;
  v_elig   jsonb;
  v_free   int;
  v_head   int;
  v_cut    timestamptz;
  v_prov   boolean;
  v_booking uuid;
  v_pass    uuid;
begin
  select * into v_occ from class_occurrences where id = p_occurrence_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  select * into v_member from members
   where studio_id = v_occ.studio_id and user_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_authorised'); end if;

  v_elig := free_first_eligibility(v_occ.studio_id, v_member.id);
  if not (v_elig ->> 'ok')::boolean then return v_elig; end if;

  select * into v_set from studio_settings where studio_id = v_occ.studio_id;
  select timezone into v_tz from studios where id = v_occ.studio_id;

  if v_occ.status <> 'scheduled' then return jsonb_build_object('ok', false, 'reason', 'class_not_bookable'); end if;
  if v_occ.starts_at <= now() then return jsonb_build_object('ok', false, 'reason', 'class_in_past'); end if;
  if not month_published(v_occ.studio_id, v_occ.starts_at) then
    return jsonb_build_object('ok', false, 'reason', 'month_not_published');
  end if;
  if studio_hides_unstaffed(v_occ.studio_id) and v_occ.staffing <> 'assigned' then
    return jsonb_build_object('ok', false, 'reason', 'not_staffed_yet');
  end if;
  if v_occ.starts_at > now() + make_interval(days => coalesce(v_set.booking_window_days, 30)) then
    return jsonb_build_object('ok', false, 'reason', 'outside_booking_window');
  end if;
  if v_occ.starts_at < now() + make_interval(mins => coalesce(v_set.booking_cutoff_minutes, 0)) then
    return jsonb_build_object('ok', false, 'reason', 'past_booking_cutoff');
  end if;

  if not coalesce(v_set.free_first_peak_allowed, true) and occurrence_is_peak(p_occurrence_id) then
    return jsonb_build_object('ok', false, 'reason', 'peak_not_allowed');
  end if;

  if v_occ.series_id is not null then
    select * into v_ser from class_series where id = v_occ.series_id;
  end if;
  v_cfg_tier := coalesce(v_occ.guarantee_tier,
                         case when v_occ.flex then 'flex'::guarantee_tier end,
                         v_ser.guarantee_tier,
                         case when v_ser.flex then 'flex'::guarantee_tier end,
                         'core'::guarantee_tier);
  if coalesce(v_set.free_first_core_only, false) and v_cfg_tier <> 'core' then
    return jsonb_build_object('ok', false, 'reason', 'flex_not_allowed');
  end if;
  if v_occ.series_id is not null
     and not coalesce(v_ser.free_first_allowed, true) then
    return jsonb_build_object('ok', false, 'reason', 'not_trial_class');
  end if;
  if v_set.free_first_seats_per_class is not null
     and (select count(*) from bookings b
           where b.occurrence_id = p_occurrence_id and b.status = 'booked'
             and b.payment_source = 'comp'
             and exists (select 1 from guest_passes gp
                          where gp.guest_booking_id = b.id and gp.host_member_id is null))
         >= v_set.free_first_seats_per_class then
    return jsonb_build_object('ok', false, 'reason', 'free_seats_full');
  end if;

  v_free := v_occ.capacity - occurrence_seats_taken(p_occurrence_id)
                           - occurrence_seats_held(p_occurrence_id);
  if v_free < 1 then return jsonb_build_object('ok', false, 'reason', 'class_full'); end if;

  v_head := occurrence_seats_taken(p_occurrence_id) + 1;
  select cutoff_at into v_cut from occurrence_guarantee_run(p_occurrence_id);
  v_prov := v_set.free_first_confirm_at is not null
            and v_cut is not null
            and v_head < v_set.free_first_confirm_at;

  insert into bookings (studio_id, occurrence_id, member_id, status, source,
                        payment_source, provisional, confirmed_at)
  values (v_occ.studio_id, p_occurrence_id, v_member.id, 'booked', 'member', 'comp',
          v_prov, case when v_prov then null else now() end)
  returning id into v_booking;
  update class_occurrences set booked_count = booked_count + 1 where id = p_occurrence_id;

  -- The shared once-ever ledger row. Decision 78: a no-show member's rebook
  -- REUSES this row (upsert on the once-ever index) rather than inserting a
  -- second — the index and its hard guarantee are untouched; the member's comp
  -- no_show bookings are what count the attempts.
  insert into guest_passes (studio_id, host_member_id, guest_member_id, guest_email,
                            occurrence_id, guest_booking_id, status, waiver_signed_at)
  values (v_occ.studio_id, null, v_member.id, lower(btrim(v_member.email)),
          p_occurrence_id, v_booking,
          case when v_member.waiver_signed_at is not null then 'confirmed' else 'invited' end,
          v_member.waiver_signed_at)
  on conflict (studio_id, normalize_email_key(guest_email)) do update
    set host_member_id   = excluded.host_member_id,
        guest_member_id  = excluded.guest_member_id,
        occurrence_id    = excluded.occurrence_id,
        guest_booking_id = excluded.guest_booking_id,
        status           = excluded.status,
        waiver_signed_at = excluded.waiver_signed_at
  returning id into v_pass;

  perform confirm_provisional_seats_run(p_occurrence_id);

  return jsonb_build_object('ok', true, 'booking_id', v_booking,
    'guest_pass_id', v_pass, 'provisional', v_prov);
end $function$;
revoke execute on function book_first_free(uuid) from public, anon;
grant  execute on function book_first_free(uuid) to authenticated;
