-- Decision 30 hotfix — a CANCELLED free first class never counts.
--
-- re-issues: free_first_eligibility(uuid, uuid)
--
-- Authorised by Deanna, 21 Oct 2026 — DDL only.
--
-- Regression from 78a (20260832550000): the host-null-pass branch returned
-- `already_had_free` in its final `else` — the case where the member booked a free
-- class and then CANCELLED it (comp booking cancelled/late_cancelled, so
-- v_comp_attended = v_comp_live = v_other_qual = 0, no membership, v_noshow = 0).
-- They never attended, so they are still a first-timer. Decision 30: a cancelled
-- free first class never counts. The trailing two arms (a single no-show → ok, the
-- cancelled-only `else`) collapse into one `else` → {ok:true}; every other arm is
-- unchanged (attended/membership/live-comp/other → already_had_free; two no-shows
-- → missed_twice). book_first_free's guest_passes upsert already reuses the single
-- once-ever ledger row on the rebook, so the index and its guarantee are untouched.
-- Re-issued verbatim from 20260832550000 with ONLY that branch changed.

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
    else
      -- Decision 30: a CANCELLED free first class never counts (v_noshow = 0, the
      -- only free booking(s) were cancelled), and a single no-show gets one more
      -- chance — either way a first-timer again. book_first_free reuses the single
      -- once-ever ledger row on the rebook.
      return jsonb_build_object('ok', true);
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
