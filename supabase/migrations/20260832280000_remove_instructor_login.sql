-- Decision 64 — removing and re-issuing an instructor's app login.
--
-- creates: remove_instructor_login(uuid)
-- re-issues: is_this_instructor(uuid), invite_instructor(uuid, text, integer)
--
-- A manager-up can take an instructor's app login off the studio: the teaching
-- record (classes, availability, pay, history) is untouched, the studio_staff
-- row is marked removed so the person can no longer sign in to this studio, any
-- pending invite is withdrawn, and the instructor can be invited again with any
-- email. It never deletes the account at the platform level.
--
-- SECURITY FIX: is_this_instructor checked only user_id = auth.uid() and ignored
-- studio_staff.status, so a REMOVED login still passed the self-guard on every
-- reader that uses it (instructor_week, instructor_open_classes, cover_available_to
-- and ~20 others). Re-issued to filter status = 'active' — one function, every
-- caller fixed. auth_role_in / auth_instructor_id / instructor_user_id /
-- my_instructor already filter status = 'active', so the role guards, the
-- instructor-identity guards and the session context already deny a removed row.
--
-- invite_instructor re-issued so a same-email re-invite reactivates the removed
-- row (the studio_staff email index is not partial, so an INSERT would conflict);
-- a different email just inserts a new row. Anon stays THIRTEEN.

alter table studio_staff add column if not exists removed_at timestamptz;

-- =============================================================================
-- (1) is_this_instructor — add the status = 'active' filter (security fix).
--     Re-issued from 20260830960000.
-- =============================================================================
create or replace function is_this_instructor(p_instructor_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(exists (
    select 1 from instructors i
      join studio_staff ss on ss.id = i.staff_id
     where i.id = p_instructor_id and ss.user_id = auth.uid() and ss.status = 'active'
  ), false);
$$;

-- =============================================================================
-- (2) remove_instructor_login — manager-up. Detach the login, mark the staff row
--     removed, withdraw the pending invite, audit.
-- =============================================================================
create function remove_instructor_login(p_instructor_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i instructors%rowtype; ss studio_staff%rowtype; v_email text; v_had_login boolean;
begin
  select * into i from instructors where id = p_instructor_id;
  if not found then raise exception 'no such instructor' using errcode = 'PT404'; end if;
  -- Manager-up of THIS studio: a front desk or a manager of another studio fails
  -- here (cross-studio → PT403).
  if not is_manager_up(i.studio_id) then
    raise exception 'only an owner or a manager can change instructor logins'
      using errcode = 'PT403';
  end if;
  if i.staff_id is null then
    raise exception '% has no app login.', i.display_name using errcode = 'PT409';
  end if;
  select * into ss from studio_staff where id = i.staff_id;
  -- A manager cannot remove their own login this way.
  if ss.user_id is not null and ss.user_id = auth.uid() then
    raise exception 'You can''t remove your own login here.' using errcode = 'PT409';
  end if;

  v_email     := ss.email;
  v_had_login := ss.user_id is not null;

  -- Detach the login from the teaching record. The instructor row — and its
  -- classes, availability, pay and history — is otherwise untouched.
  update instructors set staff_id = null where id = p_instructor_id;
  -- End this person's access to this studio. Every role/identity guard and the
  -- session context (auth_role_in, auth_instructor_id, instructor_user_id,
  -- my_instructor, is_this_instructor) filters status = 'active', so their
  -- sessions stop working on the next request.
  update studio_staff set status = 'removed', removed_at = now() where id = ss.id;
  -- Withdraw any pending invite for this instructor (invite_instructor always
  -- stamps instructor_id, so this is exact — no over-delete by email).
  delete from studio_invites
   where instructor_id = p_instructor_id and accepted_at is null;

  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (i.studio_id, auth.uid(), 'instructor.login_removed', 'instructors', p_instructor_id,
          jsonb_build_object('email', v_email, 'staff_id', ss.id,
                             'had_login', v_had_login, 'user_id', ss.user_id));

  return jsonb_build_object('ok', true, 'email', v_email, 'had_login', v_had_login);
end $$;
revoke execute on function remove_instructor_login(uuid) from public, anon;
grant  execute on function remove_instructor_login(uuid) to authenticated, service_role;

-- =============================================================================
-- (3) invite_instructor — reactivate a previously-removed staff row of the same
--     email rather than inserting a duplicate (the studio_staff email index is
--     not partial). A different email still inserts a new row. Re-issued from
--     20260831070000 with ONLY the staff_id-null branch changed; create-or-
--     replace keeps the ACL (re-asserted at the end).
-- =============================================================================
create or replace function invite_instructor(
  p_instructor_id uuid, p_email text, p_days int default 14)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  i instructors%rowtype; s studios%rowtype;
  v_email text; v_staff uuid; v_token text; v_id uuid; v_first text;
begin
  select * into i from instructors where id = p_instructor_id;
  if not found then
    raise exception 'no such instructor' using errcode = 'PT404';
  end if;
  if not is_manager_up(i.studio_id) then
    raise exception 'only an owner or a manager can invite an instructor'
      using errcode = 'PT403';
  end if;
  if i.status <> 'active' then
    raise exception 'that instructor is %, so there is nothing to invite them to',
      i.status using errcode = 'PT409';
  end if;

  v_email := lower(nullif(btrim(p_email), ''));
  -- AN INSTRUCTOR WITH NO EMAIL CANNOT BE INVITED, and is refused BY NAME
  -- rather than queueing a notification with a null address — which is what
  -- has been happening silently to all six of them.
  if v_email is null then
    raise exception '% has no email address, so there is nowhere to send an invite',
      i.display_name
      using errcode = 'PT422',
            hint = 'Add one on their record first. `instructors` carries no email '
                   'of its own — it lives on the staff row this creates.';
  end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'that does not look like an email address' using errcode = 'PT422';
  end if;

  select * into s from studios where id = i.studio_id;

  -- Already signed in? Then there is nothing to claim.
  if i.staff_id is not null and exists (
       select 1 from studio_staff ss where ss.id = i.staff_id and ss.user_id is not null) then
    raise exception '% already has a login', i.display_name using errcode = 'PT409';
  end if;

  if i.staff_id is null then
    -- Decision 64: a previously-removed staff row holds this email (the
    -- studio_staff email index is not partial), so reactivate it rather than
    -- inserting a duplicate. A different email finds no removed row and inserts.
    select ss.id into v_staff from studio_staff ss
     where ss.studio_id = i.studio_id and lower(ss.email) = v_email and ss.status = 'removed'
     limit 1;
    if v_staff is not null then
      update studio_staff
         set user_id = null, role = 'instructor', status = 'invited',
             invited_at = now(), removed_at = null
       where id = v_staff;
    else
      insert into studio_staff (studio_id, user_id, email, role, status, invited_at)
      values (i.studio_id, null, v_email, 'instructor', 'invited', now())
      returning id into v_staff;
    end if;
    update instructors set staff_id = v_staff where id = p_instructor_id;
  else
    v_staff := i.staff_id;
    update studio_staff set email = v_email, invited_at = now(), status = 'invited'
     where id = v_staff;
  end if;

  -- A resend supersedes: the old link dies, which is the whole point of
  -- sending a new one. Migration 073 learned this the hard way — keying the
  -- dedupe on the person made a resend silently do nothing.
  delete from studio_invites
   where instructor_id = p_instructor_id and accepted_at is null;

  v_token := encode(gen_random_bytes(24), 'hex');
  insert into studio_invites (studio_id, email, token_hash, expires_at,
                              created_by, role, instructor_id)
  values (i.studio_id, v_email,
          encode(digest(v_token, 'sha256'), 'hex'),
          now() + make_interval(days => greatest(1, p_days)),
          auth.uid(), 'instructor', p_instructor_id)
  returning id into v_id;

  v_first := split_part(i.display_name, ' ', 1);
  perform queue_notification(
    i.studio_id, null, 'instructor_invite',
    jsonb_build_object(
      'to_email', v_email, 'first_name', v_first,
      'studio_name', s.name, 'days', greatest(1, p_days),
      -- The raw token lives in the payload until sent, exactly as
      -- member_invite does: only its hash is on the invite row, and the email
      -- needs the token itself. It is dead the moment it is used.
      'claim_url', 'https://' || s.slug || '.studiior.app/instructor/claim/' || v_token),
    'instructor_invite:' || v_token);

  return jsonb_build_object(
    'invite_id', v_id, 'staff_id', v_staff, 'email', v_email,
    'expires_at', now() + make_interval(days => greatest(1, p_days)));
end $$;
revoke execute on function invite_instructor(uuid, text, int) from public, anon, authenticated;
grant  execute on function invite_instructor(uuid, text, int) to authenticated, service_role;

-- The anon surface is unchanged — exactly THIRTEEN pre-login functions.
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 13 then raise exception 'anon surface is % functions, expected exactly 13', n; end if;
end $$;
