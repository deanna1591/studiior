-- Decision 88 slice A — member checkout. The ONE read this screen needs that
-- has no existing reader: does the member's plan cover this class? The class
-- page uses it to route Book (covered → book inline; not covered → /checkout),
-- and the checkout page uses it to decide picker-vs-confirm. Everything else the
-- checkout screen needs (occurrence, buyable plans, intro window, desk pay,
-- guest availability) already has a reader, so no RPC bundles them — STEP 1's
-- "prefer none" kept to exactly one small, read-only, member-guarded function.
--
-- No writes. No new money code (checkout reuses xendit_begin_purchase via the
-- existing buyPlan, and apply_plan_to_unpaid settles the held booking on
-- activation, both unchanged). Anon stays THIRTEEN.
--
-- creates: member_covers_occurrence(uuid)

-- =============================================================================
-- member_covers_occurrence — true when book_class would resolve this member's
-- booking to a COVERED source (membership / pack credit), false when it would
-- fall through to a drop-in. A faithful READ mirror of book_class §2.2's
-- membership-candidate resolution: same status/grace/freeze/expiry gates, same
-- §2.1.9 class-type restriction test, same unlimited rule. book_class stays the
-- authoritative decision; this is only the routing/coverage hint, so it matches
-- exactly the four "uncovered" cases Decision 88 names: no plan, no credits
-- left, expired, or a plan that does not include this class. (Peak-exhaustion is
-- deliberately NOT treated as uncovered — the Decision's list does not include
-- it, and a peak-exhausted member still has a covering plan.)
-- =============================================================================
create or replace function member_covers_occurrence(p_occurrence_id uuid)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  v_studio    uuid;
  v_class_type uuid;
  v_starts    timestamptz;
  v_tz        text;
  v_member    uuid;
  v_today     date;
  v_grace     int;
begin
  select o.studio_id, o.class_type_id, o.starts_at, s.timezone,
         coalesce(st.payment_grace_days, 0)
    into v_studio, v_class_type, v_starts, v_tz, v_grace
    from class_occurrences o
    join studios s on s.id = o.studio_id
    left join studio_settings st on st.studio_id = o.studio_id
   where o.id = p_occurrence_id;
  if v_studio is null then
    raise exception 'no such class' using errcode = 'PT404';
  end if;
  v_today := (v_starts at time zone v_tz)::date;

  -- The caller's own member row at this studio. A stranger / non-member reads
  -- false (never another member's coverage); staff and service may ask too.
  select id into v_member from members
   where user_id = auth.uid() and studio_id = v_studio;
  if v_member is null then
    if is_manager_up(v_studio) or is_service_context() then
      return false;  -- no member in context, nothing to cover
    end if;
    raise exception 'not a member of that studio' using errcode = 'PT403';
  end if;

  return exists (
    select 1
      from memberships ms
      join membership_plans mp on mp.id = ms.plan_id
     where ms.member_id = v_member
       and ms.studio_id = v_studio
       -- §7.3 / Decision 4: past_due still covers inside the grace window.
       and (
             ms.status in ('active', 'trialing')
          or (ms.status = 'past_due'
              and now() < coalesce(ms.current_period_end, now())
                          + make_interval(days => v_grace))
       )
       -- §7.4: a frozen membership cannot book.
       and not (ms.freeze_start is not null and ms.freeze_end is not null
                and v_today between ms.freeze_start and ms.freeze_end)
       -- §6: a credit cannot be spent past its expiry.
       and (ms.expires_on is null or ms.expires_on >= v_today)
       -- priority 1–3: unlimited recurring, or any plan with credits left.
       and (
             (mp.type = 'recurring' and mp.credits_per_period is null and ms.credits_remaining is null)
          or (mp.type = 'recurring' and coalesce(ms.credits_remaining, 0) > 0)
          or (mp.type in ('class_pack', 'drop_in', 'trial') and coalesce(ms.credits_remaining, 0) > 0)
       )
       -- §2.1.9: an empty/absent class_type_ids covers everything.
       and (
             (mp.restrictions -> 'class_type_ids') is null
          or jsonb_typeof(mp.restrictions -> 'class_type_ids') <> 'array'
          or jsonb_array_length(mp.restrictions -> 'class_type_ids') = 0
          or (v_class_type is not null
              and jsonb_exists(mp.restrictions -> 'class_type_ids', v_class_type::text))
       )
  );
end $$;
revoke execute on function member_covers_occurrence(uuid) from public, anon;
grant  execute on function member_covers_occurrence(uuid) to authenticated, service_role;

-- Anon stays EXACTLY THIRTEEN.
do $$
declare n int;
begin
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'expect\_%' escape '\';
  if n <> 13 then
    raise exception 'anon surface is % (expected 13)', n;
  end if;
end $$;
