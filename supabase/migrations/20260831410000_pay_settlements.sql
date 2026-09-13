-- Proof that a studio paid an instructor. Studiior does not move money (Decision
-- 22 stands); this records a payment made ELSEWHERE — bank transfer, GCash, cash —
-- so the instructor's statement is marked paid, with the date, and "did you pay
-- me" stops. Same posture as record_manual_payment on the member side: Studiior
-- records what the studio says happened and does not verify it.

create table instructor_pay_settlements (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios on delete cascade,
  period_id     uuid not null references pay_periods on delete cascade,
  instructor_id uuid not null references instructors on delete cascade,
  paid_on       date not null,
  method        text not null check (method in ('bank_transfer','cash','gcash','card','other')),
  reference     text,
  proof_path    text,                              -- object path in the private bucket
  recorded_by   uuid references auth.users on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (period_id, instructor_id)                -- one settlement per instructor per period
);
create index pay_settlements_studio on instructor_pay_settlements (studio_id);

alter table instructor_pay_settlements enable row level security;

-- Managers read and (via the function) write all; an instructor reads their own
-- and nobody else's.
create policy pay_settlements_manager on instructor_pay_settlements for select
  using (coalesce(is_manager_up(studio_id), false));
create policy pay_settlements_self on instructor_pay_settlements for select using (
  exists (select 1 from instructors i join studio_staff ss on ss.id = i.staff_id
           where i.id = instructor_id and ss.user_id = auth.uid())
);
grant select on instructor_pay_settlements to authenticated;

-- A private bucket, per studio in the first path segment (studio-branding's
-- shape, but PRIVATE like member-avatars: a payslip is not published). The proof
-- path is <studio_id>/<instructor_id>/<file>, so the read policy can let an
-- instructor read only their own folder.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('instructor-pay-proofs', 'instructor-pay-proofs', false, 5242880,
        array['image/png','image/jpeg','image/webp','application/pdf'])
on conflict (id) do nothing;

create policy pay_proof_manager_write on storage.objects for insert to authenticated
  with check (bucket_id = 'instructor-pay-proofs'
    and coalesce(is_manager_up(((storage.foldername(name))[1])::uuid), false));
create policy pay_proof_manager_update on storage.objects for update to authenticated
  using (bucket_id = 'instructor-pay-proofs'
    and coalesce(is_manager_up(((storage.foldername(name))[1])::uuid), false));
create policy pay_proof_read on storage.objects for select to authenticated
  using (bucket_id = 'instructor-pay-proofs' and (
    coalesce(is_manager_up(((storage.foldername(name))[1])::uuid), false)
    or auth_instructor_id(((storage.foldername(name))[1])::uuid) = ((storage.foldername(name))[2])::uuid));

-- Record (or re-record) a settlement against a CLOSED period. An open period
-- cannot be marked paid — you pay what the closed statement says.
create function record_pay_settlement(p_period_id uuid, p_instructor_id uuid,
    p_paid_on date, p_method text, p_reference text default null, p_proof_path text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare pr pay_periods%rowtype; v_id uuid;
begin
  select * into pr from pay_periods where id = p_period_id;
  if not found then raise exception 'no such period' using errcode = 'PT404'; end if;
  if not coalesce(is_manager_up(pr.studio_id), false) then
    raise exception 'only owners and managers record a payment' using errcode = 'PT403';
  end if;
  if pr.status <> 'closed' then
    raise exception 'a period must be closed before it is marked paid — close it first' using errcode = 'PT409';
  end if;
  if p_method is null or p_method not in ('bank_transfer','cash','gcash','card','other') then
    raise exception 'say how it was paid' using errcode = 'PT422';
  end if;

  insert into instructor_pay_settlements (studio_id, period_id, instructor_id, paid_on, method, reference, proof_path, recorded_by)
  values (pr.studio_id, p_period_id, p_instructor_id, p_paid_on, p_method,
          nullif(btrim(coalesce(p_reference,'')), ''), p_proof_path, auth.uid())
  on conflict (period_id, instructor_id) do update
     set paid_on = excluded.paid_on, method = excluded.method, reference = excluded.reference,
         proof_path = coalesce(excluded.proof_path, instructor_pay_settlements.proof_path),
         recorded_by = excluded.recorded_by, updated_at = now()
  returning id into v_id;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (pr.studio_id, auth.uid(), 'pay_settlement.recorded', 'instructor_pay_settlements', v_id,
    jsonb_build_object('period_id', p_period_id, 'instructor_id', p_instructor_id,
                       'paid_on', p_paid_on, 'method', p_method));
  return jsonb_build_object('ok', true, 'settlement_id', v_id);
end $$;

revoke execute on function record_pay_settlement(uuid, uuid, date, text, text, text) from public, anon;
grant  execute on function record_pay_settlement(uuid, uuid, date, text, text, text) to authenticated;
