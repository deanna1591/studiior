-- Migration 186 — Decision 40 amendment 9: the ROOT CAUSE + the belt must never
-- fail silently.
--
-- The Vercel production logs for the stuck purchase showed a real error the app
-- had been hiding: POST /api/xendit/callback -> 500 "xendit callback failed
-- { code: 'PT403', message: 'that is not your member' }". That PT403 comes from
-- award_conversion_bonus_run calling the GUARDED member_first_class (see below);
-- the anon webhook and the authenticated-member belt both hit it, so activation
-- aborted. The belt returned 200 with no log because confirmWithXendit swallowed
-- the same PT403.
--
-- Two things here: (1) fix the miswired internal call (activation succeeds for
-- the webhook AND the belt), and (2) record every return-check outcome so the
-- next silent failure names itself instead of hiding behind a 200.
--
-- xendit_purchases.last_return_check_result carries the last outcome:
--   'checking'            — claim green-lit; the action is asking Xendit now
--   'completed'/'expired'/'cancelled'/'still_active' — the apply outcome
--   'get_failed:<http>'   — the Xendit GET returned non-OK (0 = network/fetch)
--   'decrypt_failed'      — the studio key could not be decrypted
--   'apply_failed:<code>' / 'claim_failed:<code>' / 'context_failed:<code>'
--   'no_session' / 'no_ciphertext' / 'session_<status>' / 'action_threw:<name>'
-- Written by the claim/apply pair and by xendit_return_check_note (member-guarded)
-- from the action's failure branches. Never a secret or a full response body
-- (the note is truncated). Exposed on the owner's "Check pending payments" list.
-- create or replace, ACL held; anon EXACTLY TWELVE.

-- =============================================================================
-- ROOT CAUSE (found in the Vercel logs): the Xendit callback 500'd with PT403
-- "that is not your member", and the belt's apply raised the same PT403 (which
-- confirmWithXendit swallowed). Every one-time Xendit activation runs
-- activate_purchase -> membership insert -> tg_award_conversion_bonus ->
-- award_conversion_bonus_run, whose body still calls member_first_class(...) by
-- NAME. Migration 086 renamed the original to member_first_class_run and made
-- member_first_class a GUARDED wrapper (is_desk_up OR is_service_context) — but
-- did not update this internal call site. The anon webhook and the authenticated
-- member belt are NEITHER desk-up NOR service-context, so member_first_class
-- raised PT403, aborting activation and rolling back the stored event. It was
-- never caught because the suite and every manual recovery ran as a superuser
-- (is_service_context() = true), and Reform only recently switched the
-- conversion bonus on for packs. Fix: call the UNGUARDED member_first_class_run,
-- the 086 pattern (internals call internals). create or replace, ACL held.
create or replace function award_conversion_bonus_run(p_membership_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  m memberships%rowtype; s studio_settings%rowtype; pl membership_plans%rowtype;
  f record; p pay_periods%rowtype; v_tz text; v_first date; v_buy date; v_id uuid;
  v_name text;
begin
  select * into m from memberships where id = p_membership_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such membership'); end if;

  select * into s from studio_settings where studio_id = m.studio_id;
  if not coalesce(s.conversion_bonus_enabled, false) then
    return jsonb_build_object('ok', true, 'awarded', false, 'reason', 'not enabled');
  end if;
  if coalesce(s.conversion_bonus_cents, 0) = 0 then
    return jsonb_build_object('ok', true, 'awarded', false, 'reason', 'bonus is zero');
  end if;

  select * into pl from membership_plans where id = m.plan_id;
  if not coalesce(pl.counts_for_conversion, false) then
    return jsonb_build_object('ok', true, 'awarded', false,
                              'reason', 'plan does not count for conversion');
  end if;

  -- The UNGUARDED internal — this runs from a trigger with no session (anon
  -- webhook) or as the buying member (belt), neither of which is desk-up or
  -- service-context, so the guarded member_first_class would refuse them.
  select * into f from member_first_class_run(m.member_id);
  if f.instructor_id is null then
    return jsonb_build_object('ok', true, 'awarded', false,
                              'reason', 'no attended class to attribute to');
  end if;

  select timezone into v_tz from studios where id = m.studio_id;
  v_first := (f.attended_at at time zone v_tz)::date;
  v_buy   := (coalesce(m.created_at, now()) at time zone v_tz)::date;
  if v_buy - v_first > coalesce(s.conversion_window_days, 30) then
    return jsonb_build_object('ok', true, 'awarded', false, 'reason', 'outside the window',
      'days', v_buy - v_first, 'window', s.conversion_window_days);
  end if;

  select btrim(coalesce(preferred_name, first_name) || ' ' || coalesce(last_name, ''))
    into v_name from members where id = m.member_id;
  p := next_open_pay_period(m.studio_id);

  begin
    insert into instructor_pay_records (
      studio_id, instructor_id, period_id, type, source_id, amount_cents, currency,
      basis, note, created_by)
    values (m.studio_id, f.instructor_id, p.id, 'conversion', m.member_id,
            s.conversion_bonus_cents,
            (select currency from studios where id = m.studio_id),
            jsonb_build_object('member_id', m.member_id, 'member_name', v_name,
              'plan_id', pl.id, 'plan_name', pl.name, 'membership_id', m.id,
              'first_class_occurrence', f.occurrence_id,
              'first_class_on', v_first, 'purchased_on', v_buy,
              'attribution', 'first_class'),
            'Conversion bonus', auth.uid())
    returning id into v_id;
  exception when unique_violation then
    return jsonb_build_object('ok', true, 'awarded', false,
                              'reason', 'this member has already converted');
  end;

  return jsonb_build_object('ok', true, 'awarded', true, 'pay_record_id', v_id,
    'instructor_id', f.instructor_id, 'amount_cents', s.conversion_bonus_cents);
end $$;
revoke execute on function award_conversion_bonus_run(uuid) from public, anon, authenticated;
grant  execute on function award_conversion_bonus_run(uuid) to service_role;

-- =============================================================================
-- INSTRUMENTATION: the belt must never fail silently.
-- =============================================================================
alter table xendit_purchases add column if not exists last_return_check_result text;

-- Re-issue claim: stamp 'checking' when it green-lights, so a purchase whose
-- action then dies before noting still shows it got as far as the Xendit ask.
create or replace function xendit_return_check_claim(p_purchase_id uuid, p_now timestamptz default now())
returns jsonb
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype;
begin
  select * into p from xendit_purchases where id = p_purchase_id for update;
  if p.id is null then raise exception 'no such purchase' using errcode = 'PT404'; end if;
  if not exists (select 1 from members m where m.id = p.member_id and m.user_id = auth.uid()) then
    raise exception 'that purchase is not yours' using errcode = 'PT403';
  end if;
  if p.status <> 'pending' then
    return jsonb_build_object('status', p.status, 'check', false);
  end if;
  if nullif(p.payment_session_id, '') is null then
    return jsonb_build_object('status', 'pending', 'check', false, 'reason', 'no_session');
  end if;
  if p.last_return_check_at is not null and p_now - p.last_return_check_at < interval '5 seconds' then
    return jsonb_build_object('status', 'pending', 'check', false, 'throttled', true);
  end if;
  update xendit_purchases
     set last_return_check_at = p_now, last_return_check_result = 'checking'
   where id = p_purchase_id;
  return jsonb_build_object('status', 'pending', 'check', true,
    'session_id', p.payment_session_id, 'studio_id', p.studio_id);
end $$;
revoke execute on function xendit_return_check_claim(uuid, timestamptz) from public, anon;
grant  execute on function xendit_return_check_claim(uuid, timestamptz) to authenticated, service_role;

-- Re-issue apply: record the outcome on the purchase alongside applying it.
create or replace function xendit_return_check_apply(p_purchase_id uuid, p_session_status text, p_payment_id text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype; v_st text := upper(coalesce(p_session_status, '')); v_outcome text;
begin
  select * into p from xendit_purchases where id = p_purchase_id for update;
  if p.id is null then raise exception 'no such purchase' using errcode = 'PT404'; end if;
  if not exists (select 1 from members m where m.id = p.member_id and m.user_id = auth.uid()) then
    raise exception 'that purchase is not yours' using errcode = 'PT403';
  end if;
  if p.status = 'succeeded' then
    update xendit_purchases set last_return_check_result = 'completed' where id = p.id;
    return jsonb_build_object('status', 'processed', 'outcome', 'succeeded');
  end if;

  if v_st = 'COMPLETED' then
    perform xendit_activate_success_internal(p.id, p_payment_id);
    insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
    values (p.studio_id, auth.uid(), 'xendit.return_check', 'xendit_purchases', p.id,
            jsonb_build_object('payment_id', nullif(p_payment_id, ''), 'source', 'return_check'));
    update xendit_purchases set last_return_check_result = 'completed' where id = p.id;
    return jsonb_build_object('status', 'processed', 'outcome', 'succeeded');
  elsif v_st in ('EXPIRED', 'CANCELED', 'CANCELLED') then
    v_outcome := case when v_st = 'EXPIRED' then 'expired' else 'cancelled' end;
    perform xendit_fail_purchase_internal(p.id, v_outcome, v_st);
    update xendit_purchases set last_return_check_result = v_outcome where id = p.id;
    return jsonb_build_object('status', 'processed', 'outcome', v_outcome);
  end if;
  update xendit_purchases set last_return_check_result = 'still_active' where id = p.id;
  return jsonb_build_object('status', 'ignored', 'reason', 'still_active');
end $$;
revoke execute on function xendit_return_check_apply(uuid, text, text) from public, anon;
grant  execute on function xendit_return_check_apply(uuid, text, text) to authenticated, service_role;

-- The action records a failure outcome for its OWN pending purchase (best-effort,
-- from a catch/return branch). Member-guarded; the result is truncated so a
-- response body or a secret can never be stored whole.
create or replace function xendit_return_check_note(p_purchase_id uuid, p_result text)
returns void
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update xendit_purchases xp
     set last_return_check_result = left(coalesce(p_result, ''), 120)
   where xp.id = p_purchase_id
     and exists (select 1 from members m where m.id = xp.member_id and m.user_id = auth.uid());
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'that purchase is not yours to note' using errcode = 'PT403';
  end if;
end $$;
revoke execute on function xendit_return_check_note(uuid, text) from public, anon;
grant  execute on function xendit_return_check_note(uuid, text) to authenticated, service_role;

do $$
declare v_n int;
begin
  select count(*) into v_n from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
   where nsp.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 12 then raise exception 'anon surface is % functions, expected 12', v_n; end if;
end $$;
