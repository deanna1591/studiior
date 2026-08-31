-- =============================================================================
-- MIGRATION 021 — the member journey timeline, derived and replayable
--
-- Data model §4 calls the timeline the signature feature and is specific about
-- how it must be written: "by one application-layer service, never by
-- scattered triggers, so it is testable and replayable." The table has existed
-- since migration 001 and nothing has ever written a row to it, so the journey
-- is empty for every member in every environment.
--
-- This is that one writer, in SQL rather than the application, for the reason
-- §4 gives: it has to be replayable. Everything it emits is *derived* from the
-- source tables, so it can be dropped and rebuilt at any time and cannot drift
-- from the truth — which is the same argument the derived-values table in §13
-- makes, and the same one behind the setup checklist reading live data instead
-- of stored flags.
--
-- What it emits, and what it deliberately does not:
--
--   joined              members.joined_on
--   attended            a check-in — the visit actually happened
--   cancelled           a cancelled or late-cancelled booking
--   payment             a payment row, whatever its state
--   membership_changed  a membership starting
--
-- `booked` is in §4's type list and is not emitted. Every attended class would
-- appear twice — booked, then attended — and a cancelled booking is already
-- carried by `cancelled`. A timeline that says the same thing twice is one
-- people stop reading.
--
-- Challenge, achievement, note and goal events belong to features that either
-- do not exist yet or are written by hand; they are not derivable, so nothing
-- here invents them. When they arrive they append rather than rebuild.
-- =============================================================================

create function rebuild_member_timeline(p_member_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_studio uuid;
  n int;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if not found then
    raise exception 'no such member' using errcode = 'PT404';
  end if;

  -- Migration 020's lesson: is_manager_up() is false rather than null for a
  -- caller who is staff of nowhere, so this guard actually fires.
  if not is_manager_up(v_studio) and not is_platform_admin() then
    raise exception 'only owners and managers may rebuild a timeline'
      using errcode = 'PT403';
  end if;

  delete from timeline_events where member_id = p_member_id;

  insert into timeline_events (studio_id, member_id, type, occurred_at, title, description, ref_table, ref_id)
  select v_studio, p_member_id, 'joined',
         (m.joined_on::timestamp at time zone s.timezone),
         'Joined the studio',
         case when m.source is null then null else 'Came via ' || m.source end,
         'members', m.id
    from members m join studios s on s.id = m.studio_id
   where m.id = p_member_id;

  insert into timeline_events (studio_id, member_id, type, occurred_at, title, description, ref_table, ref_id)
  select v_studio, p_member_id, 'attended', ci.checked_in_at,
         coalesce(o.name, 'Visit'),
         case when o.id is null
              then 'Imported from your previous system — the class is not known'
              else null end,
         'check_ins', ci.id
    from check_ins ci
    left join class_occurrences o on o.id = ci.occurrence_id
   where ci.member_id = p_member_id;

  insert into timeline_events (studio_id, member_id, type, occurred_at, title, description, ref_table, ref_id)
  select v_studio, p_member_id, 'cancelled',
         coalesce(b.cancelled_at, b.booked_at),
         case when b.is_late_cancel then 'Cancelled late' else 'Cancelled' end,
         o.name,
         'bookings', b.id
    from bookings b
    left join class_occurrences o on o.id = b.occurrence_id
   where b.member_id = p_member_id
     and b.status in ('cancelled', 'late_cancelled');

  insert into timeline_events (studio_id, member_id, type, occurred_at, title, description, ref_table, ref_id, metadata)
  select v_studio, p_member_id, 'payment',
         coalesce(p.paid_at, p.created_at),
         case p.status
           when 'succeeded'          then 'Paid'
           when 'failed'             then 'Payment failed'
           when 'refunded'           then 'Refunded'
           when 'partially_refunded' then 'Partly refunded'
           else 'Payment pending'
         end,
         p.description,
         'payments', p.id,
         jsonb_build_object('amount_cents', p.amount_cents, 'currency', p.currency,
                            'status', p.status)
    from payments p
   where p.member_id = p_member_id;

  insert into timeline_events (studio_id, member_id, type, occurred_at, title, description, ref_table, ref_id)
  select v_studio, p_member_id, 'membership_changed',
         coalesce(ms.starts_on::timestamptz, ms.created_at),
         'Started on ' || pl.name,
         null,
         'memberships', ms.id
    from memberships ms join membership_plans pl on pl.id = ms.plan_id
   where ms.member_id = p_member_id;

  select count(*) into n from timeline_events where member_id = p_member_id;
  return n;
end $$;

create function rebuild_studio_timeline(p_studio_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  if not is_manager_up(p_studio_id) and not is_platform_admin() then
    return 0;
  end if;
  for r in select id from members where studio_id = p_studio_id loop
    n := n + rebuild_member_timeline(r.id);
  end loop;
  return n;
end $$;

revoke execute on function rebuild_member_timeline(uuid) from public;
revoke execute on function rebuild_studio_timeline(uuid) from public;
grant execute on function rebuild_member_timeline(uuid) to authenticated, service_role;
grant execute on function rebuild_studio_timeline(uuid) to authenticated, service_role;

comment on function rebuild_member_timeline(uuid) is
  'Rebuilds one member''s timeline from source. Every event is derived, so this '
  'is safe to re-run and cannot drift. Data model §4.';
