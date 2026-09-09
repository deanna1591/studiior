-- =============================================================================
-- Migration 059: the member screen's three read-only sections, and documents
-- =============================================================================
-- Four things, and three of them are the same shape as everything else this
-- codebase keeps finding: a table that has existed since migration 001 with
-- nothing writing it.
--
--   member_notes / member_goals  — no writer, so every studio's CRM is empty
--   timeline_events              — rebuild_member_timeline() has been callable
--                                  since 021 and NOTHING CALLS IT except the
--                                  seed, once, at the end. Checked: the only
--                                  references in the whole repo are the seed
--                                  and migration 033. There is no trigger on
--                                  check_ins, so a member with 46 visits reads
--                                  "Nothing recorded yet" and stays that way.
--   documents                    — Chapter 6 MVP scope, never built, and
--                                  members.waiver_signed_at has been the gate
--                                  on booking with no document behind it.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. The timeline gets a writer
-- -----------------------------------------------------------------------------
-- The derivation moves into an INTERNAL function with no guard, and the public
-- rebuild_member_timeline() keeps its manager-up guard and calls it. One writer
-- with two entry points, rather than a second copy of the derivation that would
-- agree on the day it was written and drift after — the rule migration 021's
-- own comment set out and message_sent already follows.
--
-- Why a rebuild per event rather than an insert per event: the rebuild deletes
-- and re-derives, so it is idempotent by construction and CANNOT disagree with
-- itself. An append-only trigger would be a second implementation of the same
-- eleven queries, and the first one to be edited would silently diverge.
CREATE OR REPLACE FUNCTION public.rebuild_timeline_rows(p_member_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_studio uuid;
  n int;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if not found then
    raise exception 'no such member' using errcode = 'PT404';
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

  -- A draft is not an event. Only a message that has left the desk appears.
  insert into timeline_events (studio_id, member_id, type, occurred_at, title, description, actor_user_id, ref_table, ref_id, metadata)
  select v_studio, p_member_id, 'message_sent',
         coalesce(msg.sent_at, msg.updated_at),
         'Message sent',
         msg.subject,
         msg.created_by,
         'messages', msg.id,
         jsonb_build_object('status', msg.status, 'template_key', msg.template_key)
    from messages msg
   where msg.member_id = p_member_id
     and msg.status in ('queued', 'sent');

  select count(*) into n from timeline_events where member_id = p_member_id;
  return n;
end $function$;

create or replace function rebuild_member_timeline(p_member_id uuid)
returns integer
language plpgsql security definer set search_path = public as $$
declare v_studio uuid;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if not found then
    raise exception 'no such member' using errcode = 'PT404';
  end if;
  if not is_manager_up(v_studio) and not is_platform_admin() and not is_service_context() then
    raise exception 'only owners and managers may rebuild a timeline'
      using errcode = 'PT403';
  end if;
  return rebuild_timeline_rows(p_member_id);
end $$;

-- The trigger. On the SOURCE tables, because the timeline is derived from them
-- and an event written anywhere else would vanish at the next rebuild.
create or replace function tg_rebuild_timeline() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_member uuid;
begin
  v_member := case when tg_op = 'DELETE' then old.member_id else new.member_id end;
  -- The member may already be gone: deleting a member cascades to bookings and
  -- check-ins, so this fires once per cascaded row with nothing left to rebuild.
  -- timeline_events cascades too, so there is also nothing to clean up.
  -- Without this, purge_demo_data() raised "no such member" halfway through.
  if v_member is not null
     and exists (select 1 from members where id = v_member) then
    perform rebuild_timeline_rows(v_member);
  end if;
  return null;
end $$;

drop trigger if exists check_ins_timeline on check_ins;
create trigger check_ins_timeline after insert or update or delete on check_ins
  for each row execute function tg_rebuild_timeline();
drop trigger if exists bookings_timeline on bookings;
create trigger bookings_timeline after insert or update or delete on bookings
  for each row execute function tg_rebuild_timeline();
drop trigger if exists payments_timeline on payments;
create trigger payments_timeline after insert or update or delete on payments
  for each row execute function tg_rebuild_timeline();
drop trigger if exists memberships_timeline on memberships;
create trigger memberships_timeline after insert or update or delete on memberships
  for each row execute function tg_rebuild_timeline();

-- The backfill. Every studio, claimed per studio like every other job here, so
-- one studio's bad row cannot cost the rest their history.
create or replace function backfill_all_timelines() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r record; v_job uuid; n_studios int := 0; n_members int := 0;
  n_events int := 0; n_fail int := 0; n_skip int := 0;
begin
  if not is_service_context() and not is_platform_admin() then
    raise exception 'the timeline backfill runs as the backend or an operator'
      using errcode = 'PT403';
  end if;

  for r in select s.id as studio_id, (now() at time zone s.timezone)::date as local_date
             from studios s where s.status = 'active' order by s.id
  loop
    insert into job_runs (job_key, run_for, status)
    values ('timeline_backfill:' || r.studio_id, r.local_date, 'running')
    on conflict (job_key, run_for) do update
       set attempts = job_runs.attempts + 1, started_at = now(), status = 'running'
     where job_runs.status <> 'done'
    returning id into v_job;
    if v_job is null then n_skip := n_skip + 1; continue; end if;
    n_studios := n_studios + 1;

    begin
      for r in select m.id from members m where m.studio_id = r.studio_id order by m.id loop
        n_events := n_events + coalesce(rebuild_timeline_rows(r.id), 0);
        n_members := n_members + 1;
      end loop;
      update job_runs set status = 'done', finished_at = now(), error = null where id = v_job;
    exception when others then
      update job_runs set status = 'failed', finished_at = now(), error = sqlerrm where id = v_job;
      n_fail := n_fail + 1;
    end;
  end loop;

  return jsonb_build_object('studios', n_studios, 'members', n_members,
                            'events', n_events, 'failed', n_fail, 'skipped', n_skip);
end $$;

revoke execute on function rebuild_timeline_rows(uuid) from public, anon, authenticated;
revoke execute on function tg_rebuild_timeline()       from public, anon, authenticated;
revoke execute on function backfill_all_timelines()    from public, anon, authenticated;
grant execute on function backfill_all_timelines() to service_role;

-- -----------------------------------------------------------------------------
-- 2. Goals measure against real attendance
-- -----------------------------------------------------------------------------
-- member_goals.current_value is a stored column and nothing has ever moved it,
-- so every goal has read 0 of whatever it asked for. Computed live instead of
-- cached: a cache needs a writer on every check-in and this is one count.
create or replace function member_goal_progress(p_goal_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare g member_goals%rowtype; v_done int; v_from date;
begin
  select * into g from member_goals where id = p_goal_id;
  if not found then
    raise exception 'no such goal' using errcode = 'PT404';
  end if;
  if not is_desk_up(g.studio_id)
     and not exists (select 1 from members m
                      where m.id = g.member_id and m.user_id = auth.uid()) then
    raise exception 'not yours to read' using errcode = 'PT403';
  end if;

  -- Counted from when the goal was SET, not from the member's whole history.
  -- "Twelve classes" agreed in March is not already met by last year.
  v_from := g.created_at::date;
  select count(*) into v_done from check_ins ci
   where ci.member_id = g.member_id and ci.checked_in_at::date >= v_from
     and (g.target_date is null or ci.checked_in_at::date <= g.target_date);

  return jsonb_build_object(
    'goal_id', g.id, 'target_type', g.target_type, 'target_value', g.target_value,
    'done', case when g.target_type = 'class_count' then v_done else g.current_value end,
    'target_date', g.target_date,
    'met', case when g.target_type = 'class_count' and g.target_value is not null
                then v_done >= g.target_value else g.completed_at is not null end,
    'counted_from', v_from);
end $$;

revoke execute on function member_goal_progress(uuid) from public, anon, authenticated;
grant execute on function member_goal_progress(uuid) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 3. Documents
-- -----------------------------------------------------------------------------
-- Chapter 6's MVP scope, never built. The waiver is the one that matters:
-- members.waiver_signed_at has gated §2.1 booking since migration 002 with
-- nothing producing the document behind it, so "signed" has meant "somebody
-- ticked it".
create table if not exists member_documents (
  id            uuid primary key default gen_random_uuid(),
  studio_id     uuid not null references studios on delete cascade,
  member_id     uuid not null references members on delete cascade,
  kind          text not null default 'other'
                check (kind in ('waiver','medical','id','other')),
  filename      text not null,
  -- The object path inside the private bucket, NOT a URL. Same call as
  -- members.avatar_url: a URL in the column would outlive the signature.
  storage_path  text not null unique,
  mime_type     text,
  size_bytes    int,
  note          text,
  uploaded_by   uuid references profiles on delete set null,
  signed_at     timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists member_documents_member on member_documents (studio_id, member_id, created_at desc);

drop trigger if exists member_documents_updated on member_documents;
create trigger member_documents_updated before update on member_documents
  for each row execute function set_updated_at();

alter table member_documents enable row level security;
grant select, insert, update, delete on member_documents to authenticated;
grant all on member_documents to service_role;

comment on table member_documents is
  'Chapter 6 MVP scope. A waiver upload sets members.waiver_signed_at, so the '
  'booking gate and the paperwork finally agree.';

-- §14 denies instructors a member's contact details; a medical document is the
-- same rule and more so. is_desk_up() is owner/manager/front_desk and excludes
-- instructors, and MEDICAL is narrowed again to manager-up: front desk take
-- waivers at the counter and have no reason to read somebody's diagnosis.
create policy documents_staff_read on member_documents for select
  using (
    case when kind = 'medical' then is_manager_up(studio_id) else is_desk_up(studio_id) end
  );
-- INSERT / UPDATE / DELETE spelled out rather than FOR ALL. A FOR ALL policy's
-- USING clause applies to SELECT as well, and permissive policies are OR'd — so
-- a broad `for all using (is_desk_up(...))` silently grants front desk read on
-- the medical documents the narrower SELECT policy above is there to withhold.
-- Caught by the test: front desk saw 2 documents where it should see 1.
create policy documents_desk_insert on member_documents for insert
  with check (is_desk_up(studio_id));
-- The same narrowing on UPDATE, or front desk could edit a medical row they are
-- not allowed to read — an UPDATE's USING is its own visibility rule.
create policy documents_desk_update on member_documents for update
  using (case when kind = 'medical' then is_manager_up(studio_id) else is_desk_up(studio_id) end)
  with check (is_desk_up(studio_id));
create policy documents_manager_delete on member_documents for delete
  using (is_manager_up(studio_id));
-- A member sees their own, medical included — it is their body.
create policy documents_self_read on member_documents for select
  using (member_id in (select id from members where user_id = auth.uid()));

insert into storage.buckets (id, name, public, file_size_limit)
values ('member-documents', 'member-documents', false, 10485760)
on conflict (id) do nothing;

-- Path is <studio_id>/<member_id>/<file>, so the FIRST segment is the tenant
-- boundary and the second is the person — the same shape as member-avatars and
-- studio-branding.
drop policy if exists "staff upload member documents" on storage.objects;
create policy "staff upload member documents" on storage.objects for insert
  with check (bucket_id = 'member-documents'
    and is_desk_up(((storage.foldername(name))[1])::uuid));

drop policy if exists "staff replace member documents" on storage.objects;
create policy "staff replace member documents" on storage.objects for update
  using (bucket_id = 'member-documents'
    and is_desk_up(((storage.foldername(name))[1])::uuid));

drop policy if exists "staff delete member documents" on storage.objects;
create policy "staff delete member documents" on storage.objects for delete
  using (bucket_id = 'member-documents'
    and is_manager_up(((storage.foldername(name))[1])::uuid));

-- Read: staff of that studio, or the member the second segment names. The
-- medical narrowing lives on the ROW, and the object is only ever reached
-- through a signed URL the app asks for after reading the row — so a member of
-- another studio cannot reach either.
drop policy if exists "member documents are readable by staff and their owner" on storage.objects;
create policy "member documents are readable by staff and their owner" on storage.objects for select
  using (bucket_id = 'member-documents'
    and (is_desk_up(((storage.foldername(name))[1])::uuid)
         or exists (select 1 from members m
                     where m.id = ((storage.foldername(name))[2])::uuid
                       and m.user_id = auth.uid())));

-- Recording one, and the waiver's side effect
create or replace function record_document(
  p_member_id uuid, p_kind text, p_filename text, p_storage_path text,
  p_mime text default null, p_size int default null, p_note text default null,
  p_signed_at timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_studio uuid; v_id uuid; v_waiver boolean := false;
begin
  select studio_id into v_studio from members where id = p_member_id;
  if v_studio is null then
    raise exception 'no such member' using errcode = 'PT404';
  end if;
  if not is_desk_up(v_studio) then
    raise exception 'only front desk and above may file a document'
      using errcode = 'PT403';
  end if;
  if p_kind not in ('waiver','medical','id','other') then
    raise exception 'kind must be waiver, medical, id or other' using errcode = 'PT422';
  end if;

  insert into member_documents
    (studio_id, member_id, kind, filename, storage_path, mime_type, size_bytes,
     note, uploaded_by, signed_at)
  values (v_studio, p_member_id, p_kind, p_filename, p_storage_path, p_mime,
          p_size, nullif(btrim(coalesce(p_note,'')), ''), auth.uid(),
          case when p_kind = 'waiver' then coalesce(p_signed_at, now()) end)
  returning id into v_id;

  -- THE POINT OF THE WAIVER CASE. members.waiver_signed_at is §2.1's booking
  -- gate and has been set by hand since migration 001; filing the signed
  -- document is what should set it, so the gate and the paperwork agree.
  -- guard_member_self_update() protects waiver_signed_at from the MEMBER, not
  -- from the desk, and this runs as the desk.
  if p_kind = 'waiver' then
    update members
       set waiver_signed_at = coalesce(p_signed_at, now())
     where id = p_member_id and waiver_signed_at is null;
    v_waiver := found;
  end if;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (v_studio, auth.uid(), 'document.filed', 'member_documents', v_id,
          jsonb_build_object('kind', p_kind, 'filename', p_filename,
                             'member_id', p_member_id, 'waiver_set', v_waiver));

  return jsonb_build_object('ok', true, 'document_id', v_id, 'waiver_signed', v_waiver);
end $$;

revoke execute on function record_document(uuid, text, text, text, text, int, text, timestamptz)
  from public, anon, authenticated;
grant execute on function record_document(uuid, text, text, text, text, int, text, timestamptz)
  to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 4. Staff can upload a member's photo on their behalf
-- -----------------------------------------------------------------------------
-- member-avatars has been readable by staff since migration 035 and writable
-- only by the member themselves — so a walk-in signing up at the desk, who is
-- exactly the person who will not do it themselves, could never have one.
-- The path's first segment is the member id, same as the member's own policy.
drop policy if exists "staff upload a member avatar" on storage.objects;
create policy "staff upload a member avatar" on storage.objects for insert
  with check (bucket_id = 'member-avatars'
    and exists (select 1 from members m
                 where m.id = ((storage.foldername(name))[1])::uuid
                   and is_desk_up(m.studio_id)));

drop policy if exists "staff replace a member avatar" on storage.objects;
create policy "staff replace a member avatar" on storage.objects for update
  using (bucket_id = 'member-avatars'
    and exists (select 1 from members m
                 where m.id = ((storage.foldername(name))[1])::uuid
                   and is_desk_up(m.studio_id)));

-- members.avatar_url is protected from the MEMBER by guard_member_self_update()
-- (it is not in their owned list), and staff write it through the ordinary
-- members policies. Nothing new is needed for the column itself.
