-- Migration 183 — Decision 40 amendment 6: reuse the Xendit customer, don't
-- recreate it.
--
-- A member's SECOND checkout failed 409 "customer: The reference_id entered has
-- been used before" — the first checkout created a Xendit customer with
-- reference_id = our member id, and Xendit refuses to create it again. We must
-- store the returned customer_id and send it (as customer_id, not a customer
-- object) on subsequent checkouts.
--
-- Stored in a small provider-scoped table (rather than a column on members) so
-- guard_member_self_update is untouched and a second provider slots in later.
-- RLS: a member reads only their own; desk-up staff of the studio read theirs.
-- The writer is SECURITY DEFINER (a member cannot write the table directly).

create table member_payment_customers (
  studio_id    uuid not null references studios on delete cascade,
  member_id    uuid not null references members on delete cascade,
  provider     payment_provider not null,
  customer_ref text not null,   -- Xendit's cust-…
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  primary key (member_id, provider)
);
create index on member_payment_customers (studio_id, provider);
create trigger member_payment_customers_updated before update on member_payment_customers
  for each row execute function set_updated_at();

alter table member_payment_customers enable row level security;
create policy mpc_member_self on member_payment_customers for select using (
  exists (select 1 from members m where m.id = member_payment_customers.member_id and m.user_id = auth.uid())
);
create policy mpc_staff_read on member_payment_customers for select using (is_desk_up(studio_id));
-- No client INSERT/UPDATE: the writer below is the only one.
grant select on member_payment_customers to authenticated;
grant all on member_payment_customers to service_role;

-- The member stores their own Xendit customer id (own row; guarded to auth.uid()).
create function xendit_set_customer(p_studio_id uuid, p_customer_id text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_member uuid;
begin
  select id into v_member from members where studio_id = p_studio_id and user_id = auth.uid();
  if v_member is null then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;
  if nullif(p_customer_id, '') is null then return; end if;
  insert into member_payment_customers (studio_id, member_id, provider, customer_ref)
  values (p_studio_id, v_member, 'xendit', p_customer_id)
  on conflict (member_id, provider) do update set customer_ref = excluded.customer_ref, updated_at = now();
end $$;

revoke execute on function xendit_set_customer(uuid, text) from public, anon;
grant  execute on function xendit_set_customer(uuid, text) to authenticated, service_role;

do $$
declare v_n int;
begin
  select count(*) into v_n from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
   where nsp.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 12 then raise exception 'anon surface is % functions, expected 12', v_n; end if;
end $$;
