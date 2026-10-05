-- Decision 64 follow-up — re-issue remove_instructor_login's own-login check in
-- the coalesce() form the null-guard check (scripts/check-null-guards.py) wants.
--
-- re-issues: remove_instructor_login(uuid)
--
-- The 228 body wrote `if ss.user_id is not null and ss.user_id = auth.uid()` —
-- already null-safe (an invited row with no user_id is not "your own login"), but
-- the lint flags any bare `= auth.uid()` outside coalesce()/exists() (migrations
-- 020/035/129/130). `coalesce(ss.user_id = auth.uid(), false)` is identical in
-- behaviour (false when user_id is null) and is the idiomatic form. Byte-for-byte
-- 228 otherwise; create-or-replace keeps the ACL (re-asserted).

create or replace function remove_instructor_login(p_instructor_id uuid)
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
  -- A manager cannot remove their own login this way. coalesce keeps it null-safe
  -- (an invited row with no user_id is nobody's "own login").
  if coalesce(ss.user_id = auth.uid(), false) then
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
