-- Decision 15 amendment — a purchase activates the member.
-- When a membership, pack, intro offer or trial is created for a member whose
-- status is lead, the member becomes active in the same transaction, whatever
-- the creation path (online, desk, staff grant, import). The flip is recorded
-- as a membership_events row and an audit row. activate_purchase and
-- sell_plan_at_desk are UNTOUCHED: a trigger on memberships after insert covers
-- every path. Existing leads holding an active or trialing membership are
-- activated once by the backfill below, with the same audit.

-- creates: tg_membership_activates_lead()

-- ===========================================================================
-- The trigger: a membership created for a lead activates the lead. status is in
-- guard_member_self_update's owned set and every creation path runs as service,
-- desk or a non-member actor, so the members update is never blocked and no
-- transaction-local flag is needed.
-- ===========================================================================
create or replace function tg_membership_activates_lead() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_status member_status;
begin
  select status into v_status from members where id = new.member_id;
  if v_status = 'lead' then
    update members set status = 'active', updated_at = now()
     where id = new.member_id and status = 'lead';
    insert into membership_events (studio_id, membership_id, type, actor_user_id, metadata)
      values (new.studio_id, new.id, 'member_activated', auth.uid(),
              jsonb_build_object('member_from', 'lead', 'member_to', 'active', 'reason', 'purchase'));
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
      values (new.studio_id, auth.uid(), 'member.status_changed', 'members', new.member_id,
              jsonb_build_object('status', 'lead'),
              jsonb_build_object('status', 'active',
                                 'note', 'lead to active on membership creation, Decision 15 amendment'));
  end if;
  return new;
end $$;
revoke execute on function tg_membership_activates_lead() from public, anon, authenticated;

drop trigger if exists membership_activates_lead on memberships;
create trigger membership_activates_lead after insert on memberships
  for each row execute function tg_membership_activates_lead();

-- ===========================================================================
-- One-time backfill: existing leads holding an active or trialing membership
-- are activated, with the same membership_events + audit rows. Idempotent (only
-- rows still status='lead' are touched; a re-apply would find none).
-- ===========================================================================
do $$
declare r record; v_n int := 0;
begin
  for r in
    select distinct on (m.id) m.id as member_id, m.studio_id, ms.id as membership_id
      from members m
      join memberships ms on ms.member_id = m.id and ms.status in ('active','trialing')
     where m.status = 'lead' and m.deleted_at is null
     order by m.id, ms.created_at
  loop
    update members set status = 'active', updated_at = now()
     where id = r.member_id and status = 'lead';
    insert into membership_events (studio_id, membership_id, type, actor_user_id, metadata)
      values (r.studio_id, r.membership_id, 'member_activated', null,
              jsonb_build_object('member_from', 'lead', 'member_to', 'active',
                                 'reason', 'purchase', 'backfill', true));
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, before, after)
      values (r.studio_id, null, 'member.status_changed', 'members', r.member_id,
              jsonb_build_object('status', 'lead'),
              jsonb_build_object('status', 'active',
                                 'note', 'lead to active, Decision 15 amendment backfill'));
    v_n := v_n + 1;
  end loop;
  raise notice 'Decision 15 amendment backfill: % lead(s) activated', v_n;
end $$;

-- --- Anon stays EXACTLY THIRTEEN --------------------------------------------
do $$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % (want 13)', n; end if;
end $$;
