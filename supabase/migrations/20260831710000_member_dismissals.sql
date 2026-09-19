-- =============================================================================
-- 166  member_dismissals — a per-member, persistent "I dismissed this" row for
--      app affordances that are not announcements (the free-first banner today).
-- =============================================================================
-- Per member and durable, NOT localStorage (which is per device) — the same
-- reason announcement_dismissals is a row. Keyed on a text `key` so one table
-- serves any dismissable non-announcement UI. A member self-inserts under RLS;
-- there is no writer function to add.
--
-- The free-first banner uses key 'free_first_banner': dismissing it hides the
-- banner for that member for good, while the "Book — first class free" row
-- buttons keep carrying the offer as long as they are eligible — so nothing is
-- lost, and when eligibility ends the banner is gone regardless.
-- =============================================================================
create table if not exists member_dismissals (
  member_id    uuid not null references members on delete cascade,
  key          text not null,
  dismissed_at timestamptz not null default now(),
  primary key (member_id, key)
);
comment on table member_dismissals is
  'Per-member dismissals of non-announcement UI (e.g. free_first_banner). A row, '
  'not localStorage, so it persists across devices.';

alter table member_dismissals enable row level security;
-- The member reads and inserts their own, exactly like announcement_dismissals.
create policy member_dismissals_self on member_dismissals for all using (
  member_id in (select id from members where user_id = auth.uid())
) with check (
  member_id in (select id from members where user_id = auth.uid())
);
grant select, insert on member_dismissals to authenticated;
grant all on member_dismissals to service_role;

-- Nothing here is anon; assert the surface is unchanged at apply time.
do $$
declare v_n int;
begin
  select count(*) into v_n from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
   where nsp.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 11 then raise exception 'anon surface is % functions, expected 11', v_n; end if;
end $$;
