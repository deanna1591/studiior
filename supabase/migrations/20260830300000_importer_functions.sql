-- =============================================================================
-- MIGRATION 019 — the importer: dry run, commit, rollback
--
-- Completes the work migration 016 started. Three types in dependency order:
-- members, then memberships, then attendance.
--
-- The split between TypeScript and SQL follows where the difficulty actually
-- is. Parsing a real Mindbody or Glofox export — quoted commas, three date
-- formats in one column, names in one field or two — is string work, and it
-- happens in the application, which writes what it made of each row into
-- import_rows.normalized. Deciding whether that row can be created, and
-- creating it, is database work: it needs the studio's existing members, its
-- plans, and a transaction. That is here.
--
-- import_rows.status is the contract between the two halves:
--   pending  the application parsed it, nothing has judged it yet
--   ok       will be created on commit
--   skip     nothing to do — already present. Not an error, and said so.
--   error    cannot be created, with the reason in import_rows.error
--
-- Only 'ok' rows are committed. A dry run writes nothing but import_rows.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Status words, in one place
--
-- A file says "Active"; the enum says 'active'. Casting the raw value straight
-- to the enum makes an ordinary export blow up mid-commit — which is the one
-- place it must not, because the dry run has already told the owner it was
-- safe. Anything the dry run cannot resolve here is an error at review, where
-- an error is free.
--
-- Case and spacing are forgiven, and a short list of unambiguous synonyms with
-- them. Nothing beyond that is guessed at: silently filing an unrecognised
-- word as 'active' would tell the owner their lapsed members are current, and
-- there is no way for them to find out afterwards that it happened.
-- -----------------------------------------------------------------------------
create function import_member_status(p text) returns member_status
language sql immutable set search_path = public as $$
  select case regexp_replace(lower(coalesce(p, '')), '[^a-z]', '', 'g')
    when 'active'    then 'active'
    when 'current'   then 'active'
    when 'live'      then 'active'
    when 'inactive'  then 'inactive'
    when 'cancelled' then 'inactive'
    when 'canceled'  then 'inactive'
    when 'expired'   then 'inactive'
    when 'lapsed'    then 'inactive'
    when 'former'    then 'inactive'
    when 'archived'  then 'archived'
    when 'deleted'   then 'archived'
    when 'removed'   then 'archived'
    when 'lead'      then 'lead'
    when 'prospect'  then 'lead'
    when 'enquiry'   then 'lead'
    when 'inquiry'   then 'lead'
  end::member_status
$$;

create function import_membership_status(p text) returns membership_status
language sql immutable set search_path = public as $$
  select case regexp_replace(lower(coalesce(p, '')), '[^a-z]', '', 'g')
    when 'active'    then 'active'
    when 'current'   then 'active'
    when 'trialing'  then 'trialing'
    when 'trial'     then 'trialing'
    when 'pastdue'   then 'past_due'
    when 'overdue'   then 'past_due'
    when 'unpaid'    then 'past_due'
    when 'frozen'    then 'frozen'
    when 'paused'    then 'frozen'
    when 'onhold'    then 'frozen'
    when 'hold'      then 'frozen'
    when 'suspended' then 'frozen'
    when 'cancelled' then 'cancelled'
    when 'canceled'  then 'cancelled'
    when 'expired'   then 'expired'
    when 'ended'     then 'expired'
    when 'lapsed'    then 'expired'
  end::membership_status
$$;

revoke execute on function import_member_status(text) from public;
revoke execute on function import_membership_status(text) from public;
grant execute on function import_member_status(text) to authenticated, service_role;
grant execute on function import_membership_status(text) to authenticated, service_role;

create function import_dry_run(p_import_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  imp    imports%rowtype;
  n_ok   int; n_skip int; n_err int;
begin
  select * into imp from imports where id = p_import_id;
  if not found then
    raise exception 'no such import' using errcode = 'PT404';
  end if;
  if not is_manager_up(imp.studio_id) then
    raise exception 'only owners and managers may import'
      using errcode = 'PT403';
  end if;

  -- Re-runnable: a dry run judges every row again from scratch, so correcting
  -- the mapping and running it a second time cannot leave stale verdicts.
  update import_rows
     set status = 'pending', error = null
   where import_id = p_import_id and status <> 'committed';

  if imp.type = 'members' then
    update import_rows r set status = 'error', error = e.msg
      from (
        select r2.id,
               case
                 when coalesce(r2.normalized ->> 'email', '') = '' then
                   'No email address in this row'
                 when (r2.normalized ->> 'email') !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
                   format('%s is not an email address', r2.normalized ->> 'email')
                 when coalesce(r2.normalized ->> 'first_name', '') = ''
                  and coalesce(r2.normalized ->> 'last_name', '') = '' then
                   'No name in this row'
                 -- The file disagreeing with itself is the owner's problem to
                 -- fix, not something to silently pick a winner for.
                 when (select count(*) from import_rows d
                        where d.import_id = p_import_id
                          and lower(d.normalized ->> 'email')
                              = lower(r2.normalized ->> 'email')) > 1 then
                   format('%s appears more than once in this file',
                          r2.normalized ->> 'email')
                 when coalesce(r2.normalized ->> 'status', '') <> ''
                  and import_member_status(r2.normalized ->> 'status') is null then
                   format('"%s" is not a member status — use active, inactive, '
                          'archived or lead, or leave the column unmapped',
                          r2.normalized ->> 'status')
               end as msg
          from import_rows r2 where r2.import_id = p_import_id and r2.status = 'pending'
      ) e
     where r.id = e.id and e.msg is not null;

    -- members_email is unique on (studio_id, lower(email)). Already-present is
    -- not a failure — a second import of an overlapping export is a normal
    -- thing to do — so it skips and says which row it matched.
    update import_rows r set status = 'skip',
           error = format('%s is already a member', r.normalized ->> 'email')
     where r.import_id = p_import_id and r.status = 'pending'
       and exists (select 1 from members m
                    where m.studio_id = imp.studio_id
                      and lower(m.email) = lower(r.normalized ->> 'email'));

  elsif imp.type = 'memberships' then
    update import_rows r set status = 'error', error = e.msg
      from (
        select r2.id,
               case
                 when coalesce(r2.normalized ->> 'email', '') = '' then
                   'No member email in this row'
                 when not exists (select 1 from members m
                                   where m.studio_id = imp.studio_id
                                     and lower(m.email) = lower(r2.normalized ->> 'email')) then
                   format('No member with the email %s — import members first',
                          r2.normalized ->> 'email')
                 when coalesce(r2.normalized ->> 'plan', '') = '' then
                   'No plan name in this row'
                 when not exists (select 1 from membership_plans p
                                   where p.studio_id = imp.studio_id
                                     and lower(p.name) = lower(r2.normalized ->> 'plan')) then
                   format('No plan called "%s" in this studio', r2.normalized ->> 'plan')
                 when coalesce(r2.normalized ->> 'status', '') <> ''
                  and import_membership_status(r2.normalized ->> 'status') is null then
                   format('"%s" is not a membership status — use active, trialing, '
                          'past due, frozen, cancelled or expired, or leave the '
                          'column unmapped', r2.normalized ->> 'status')
               end as msg
          from import_rows r2 where r2.import_id = p_import_id and r2.status = 'pending'
      ) e
     where r.id = e.id and e.msg is not null;

  elsif imp.type = 'attendance' then
    update import_rows r set status = 'error', error = e.msg
      from (
        select r2.id,
               case
                 when coalesce(r2.normalized ->> 'email', '') = '' then
                   'No member email in this row'
                 when not exists (select 1 from members m
                                   where m.studio_id = imp.studio_id
                                     and lower(m.email) = lower(r2.normalized ->> 'email')) then
                   format('No member with the email %s — import members first',
                          r2.normalized ->> 'email')
                 when coalesce(r2.normalized ->> 'attended_at', '') = '' then
                   'No date in this row'
                 when (r2.normalized ->> 'attended_at')::timestamptz > now() then
                   'That visit is in the future'
               end as msg
          from import_rows r2 where r2.import_id = p_import_id and r2.status = 'pending'
      ) e
     where r.id = e.id and e.msg is not null;

  else
    raise exception 'unknown import type %', imp.type using errcode = 'PT422';
  end if;

  update import_rows set status = 'ok'
   where import_id = p_import_id and status = 'pending';

  select count(*) filter (where status = 'ok'),
         count(*) filter (where status = 'skip'),
         count(*) filter (where status = 'error')
    into n_ok, n_skip, n_err
    from import_rows where import_id = p_import_id;

  update imports
     set status      = 'dry_run_complete',
         row_count   = n_ok + n_skip + n_err,
         error_count = n_err,
         report      = jsonb_build_object('ok', n_ok, 'skip', n_skip, 'error', n_err)
   where id = p_import_id;

  return jsonb_build_object('ok', n_ok, 'skip', n_skip, 'error', n_err);
end $$;

-- =============================================================================
-- Commit — one transaction, and entity_id is what makes it undoable
-- =============================================================================

create function import_commit(p_import_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  imp     imports%rowtype;
  r       record;
  created int := 0;
  mid     uuid;
  touched uuid[] := '{}';
begin
  select * into imp from imports where id = p_import_id for update;
  if not found then
    raise exception 'no such import' using errcode = 'PT404';
  end if;
  if not is_manager_up(imp.studio_id) then
    raise exception 'only owners and managers may import' using errcode = 'PT403';
  end if;
  if imp.status <> 'dry_run_complete' then
    raise exception 'run the dry run first — this import is %', imp.status
      using errcode = 'PT409',
            hint = 'Nothing is committed until the owner has seen what will happen.';
  end if;

  for r in select * from import_rows
            where import_id = p_import_id and status = 'ok' order by row_number
  loop
    if imp.type = 'members' then
      insert into members (studio_id, first_name, last_name, email, phone,
                           joined_on, status, waiver_signed_at)
      values (imp.studio_id,
              coalesce(nullif(r.normalized ->> 'first_name', ''), '—'),
              coalesce(nullif(r.normalized ->> 'last_name', ''), '—'),
              lower(r.normalized ->> 'email'),
              nullif(r.normalized ->> 'phone', ''),
              coalesce((r.normalized ->> 'joined_on')::date, current_date),
              coalesce(import_member_status(r.normalized ->> 'status'), 'active'),
              (r.normalized ->> 'waiver_signed_at')::timestamptz)
      returning id into mid;

      update import_rows set entity_table = 'members', entity_id = mid,
                             status = 'committed'
       where id = r.id;

    elsif imp.type = 'memberships' then
      insert into memberships (studio_id, member_id, plan_id, status, price_cents,
                               currency, starts_on, expires_on, credits_remaining)
      select imp.studio_id, m.id, p.id,
             coalesce(import_membership_status(r.normalized ->> 'status'), 'active'),
             -- §7.1: the price is snapshotted at purchase. An import carries
             -- what they actually paid when it is in the file, and falls back
             -- to today's plan price only when it is not.
             coalesce((r.normalized ->> 'price_cents')::int, p.price_cents),
             p.currency,
             coalesce((r.normalized ->> 'starts_on')::date, current_date),
             (r.normalized ->> 'expires_on')::date,
             coalesce((r.normalized ->> 'credits_remaining')::int,
                      p.credits, p.credits_per_period)
        from members m, membership_plans p
       where m.studio_id = imp.studio_id
         and lower(m.email) = lower(r.normalized ->> 'email')
         and p.studio_id = imp.studio_id
         and lower(p.name) = lower(r.normalized ->> 'plan')
      returning id into mid;

      update import_rows set entity_table = 'memberships', entity_id = mid,
                             status = 'committed'
       where id = r.id;

    else  -- attendance
      -- No occurrence and no booking: the class this visit belonged to is not
      -- in the export and inventing one would put thousands of classes that
      -- never ran into the calendar. import_id carries the provenance and
      -- exempts the row from the §8 check-in window, which is about people
      -- arriving, not about recording that they did.
      insert into check_ins (studio_id, booking_id, member_id, occurrence_id,
                             checked_in_at, method, import_id)
      select imp.studio_id, null, m.id, null,
             (r.normalized ->> 'attended_at')::timestamptz, 'staff', p_import_id
        from members m
       where m.studio_id = imp.studio_id
         and lower(m.email) = lower(r.normalized ->> 'email')
      returning id, member_id into mid, mid;

      select m.id into mid from members m
       where m.studio_id = imp.studio_id
         and lower(m.email) = lower(r.normalized ->> 'email');
      touched := touched || mid;

      update import_rows set entity_table = 'check_ins',
                             entity_id = (select ci.id from check_ins ci
                                           where ci.import_id = p_import_id
                                             and ci.member_id = mid
                                           order by ci.created_at desc limit 1),
                             status = 'committed'
       where id = r.id;
    end if;

    created := created + 1;
  end loop;

  update imports set status = 'complete' where id = p_import_id;

  -- Imported attendance changes what every visit-derived number means.
  if imp.type = 'attendance' and array_length(touched, 1) is not null then
    perform recompute_member_stats(imp.studio_id, touched);
    perform refresh_studio_health(imp.studio_id);
  end if;

  return jsonb_build_object('created', created, 'type', imp.type);
end $$;

-- =============================================================================
-- Rollback — one action, and it refuses when it cannot be clean
-- =============================================================================

create function import_rollback(p_import_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  imp      imports%rowtype;
  removed  int := 0;
  blocking int;
  ids      uuid[];
begin
  select * into imp from imports where id = p_import_id for update;
  if not found then
    raise exception 'no such import' using errcode = 'PT404';
  end if;
  if not is_manager_up(imp.studio_id) then
    raise exception 'only owners and managers may import' using errcode = 'PT403';
  end if;
  if imp.status <> 'complete' then
    raise exception 'only a completed import can be rolled back — this one is %',
      imp.status using errcode = 'PT409';
  end if;

  select array_agg(entity_id) into ids
    from import_rows where import_id = p_import_id and entity_id is not null;

  if imp.type = 'members' and ids is not null then
    -- Deleting a member cascades their memberships, bookings, check-ins and
    -- ledger. If a LATER import attached any of that, rolling this one back
    -- would silently take the later one with it. Refusing is recoverable —
    -- roll the later import back first — and cascading is not.
    select count(*) into blocking
      from import_rows later
      join imports li on li.id = later.import_id
     where li.studio_id = imp.studio_id
       and li.id <> p_import_id
       and li.created_at > imp.created_at
       and later.entity_id is not null
       and (
         exists (select 1 from memberships x where x.id = later.entity_id and x.member_id = any(ids))
      or exists (select 1 from check_ins   x where x.id = later.entity_id and x.member_id = any(ids))
       );

    if blocking > 0 then
      raise exception
        'cannot roll back: % row(s) from a later import belong to these members',
        blocking
        using errcode = 'PT409',
              hint = 'Roll the later import back first, then this one.';
    end if;

    delete from members where studio_id = imp.studio_id and id = any(ids);
    get diagnostics removed = row_count;

  elsif imp.type = 'memberships' and ids is not null then
    delete from memberships where studio_id = imp.studio_id and id = any(ids);
    get diagnostics removed = row_count;

  elsif imp.type = 'attendance' then
    -- Keyed on import_id rather than the recorded ids: same rows, and it also
    -- catches anything the commit wrote but failed to record.
    delete from check_ins where import_id = p_import_id;
    get diagnostics removed = row_count;
  end if;

  update import_rows set status = 'rolled_back' where import_id = p_import_id;
  update imports set status = 'rolled_back' where id = p_import_id;

  if imp.type = 'attendance' then
    perform recompute_member_stats(imp.studio_id);
    perform refresh_studio_health(imp.studio_id);
  end if;

  return jsonb_build_object('removed', removed, 'type', imp.type);
end $$;

revoke execute on function import_dry_run(uuid)  from public, anon;
revoke execute on function import_commit(uuid)   from public, anon;
revoke execute on function import_rollback(uuid) from public, anon;
grant execute on function import_dry_run(uuid)  to authenticated, service_role;
grant execute on function import_commit(uuid)   to authenticated, service_role;
grant execute on function import_rollback(uuid) to authenticated, service_role;
