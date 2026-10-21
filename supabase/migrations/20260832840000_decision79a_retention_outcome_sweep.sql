-- Decision 79a — the outcome sweep. For every contact still waiting on a verdict,
-- look for a booking, a check-in, a purchase or a renewal AFTER it was made; set
-- the outcome and the day offset. Fourteen days with nothing is 'none'.
--
-- This is its OWN function and cron, NOT folded into convert_keep_sweep: a studio
-- can email from the retention board without the convert/keep sequences on, and
-- convert_keep_sweep_all only loops studios that have a sequence switched on, so
-- those contacts would never be checked. This runs for every studio.
--
-- creates: retention_outcome_sweep(timestamptz)

create or replace function retention_outcome_sweep(p_now timestamptz default now())
returns int language plpgsql security definer set search_path = public as $$
declare mc record; n int := 0;
  v_pay timestamptz; v_visit timestamptz; v_book timestamptz; v_sig timestamptz;
  v_outcome text; v_prior boolean;
begin
  for mc in
    select id, member_id, contacted_at from member_contacts
     where outcome is null and contacted_at <= p_now
  loop
    v_pay := (select min(coalesce(p.paid_at, p.created_at)) from payments p
               where p.member_id = mc.member_id
                 and p.status in ('succeeded', 'partially_refunded')
                 and p.membership_id is not null
                 and coalesce(p.paid_at, p.created_at) > mc.contacted_at);
    v_visit := (select min(ci.checked_in_at) from check_ins ci
                 where ci.member_id = mc.member_id and ci.checked_in_at > mc.contacted_at);
    v_book := (select min(b.booked_at) from bookings b
                where b.member_id = mc.member_id and b.status in ('booked', 'attended')
                  and b.booked_at > mc.contacted_at);

    if v_pay is not null then
      -- A member who already held a membership before we reached out has renewed;
      -- a first-ever purchase is a conversion.
      v_prior := exists (select 1 from memberships ms
                          where ms.member_id = mc.member_id and ms.created_at < mc.contacted_at);
      v_outcome := case when v_prior then 'renewed' else 'bought' end;
      v_sig := v_pay;
    elsif v_visit is not null then
      v_outcome := 'visited'; v_sig := v_visit;
    elsif v_book is not null then
      v_outcome := 'booked'; v_sig := v_book;
    else
      v_outcome := null; v_sig := null;
    end if;

    if v_sig is not null then
      update member_contacts
         set outcome = v_outcome, outcome_at = v_sig,
             outcome_days = greatest(0, floor(extract(epoch from (v_sig - mc.contacted_at)) / 86400))::int
       where id = mc.id;
      n := n + 1;
    elsif p_now - mc.contacted_at >= interval '14 days' then
      update member_contacts
         set outcome = 'none', outcome_at = p_now, outcome_days = 14
       where id = mc.id;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke execute on function retention_outcome_sweep(timestamptz) from public, anon, authenticated;
grant  execute on function retention_outcome_sweep(timestamptz) to service_role;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin perform cron.unschedule('studiior-retention-outcomes'); exception when others then null; end;
    perform cron.schedule('studiior-retention-outcomes', '30 3 * * *',
      $c$select retention_outcome_sweep()$c$);
  end if;
end $$;
