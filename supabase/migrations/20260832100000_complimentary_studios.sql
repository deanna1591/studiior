-- =============================================================================
-- Decision 53 — complimentary (house) studios: the columns, the set/clear
-- functions, and the one reader that would overwrite the status (the Stripe
-- webhook handler) re-issued to skip a comp studio.
--
-- re-issues: stripe_platform_handle(text, jsonb)
-- creates: set_studio_complimentary(uuid, text), clear_studio_complimentary(uuid)
--
-- The other readers need no change: 'complimentary' is a status outside
-- {trialing, past_due, locked}, and sweep_platform_billing, studio_is_locked and
-- the bootstrap billing_locked all filter on those, so a comp studio is never
-- lapsed, warned or locked.
-- =============================================================================

alter table platform_subscriptions add column if not exists comp_note   text;
alter table platform_subscriptions add column if not exists comp_set_by uuid;
alter table platform_subscriptions add column if not exists comp_set_at  timestamptz;

comment on column platform_subscriptions.comp_note is
  'Decision 53: why this studio is complimentary (set from /admin/billing).';

-- ---- set / clear (platform-admin only) --------------------------------------
create or replace function set_studio_complimentary(p_studio_id uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_platform_admin() then
    raise exception 'only a platform admin can comp a studio' using errcode = 'PT403';
  end if;
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'a complimentary studio needs a note' using errcode = 'PT400';
  end if;
  update platform_subscriptions
     set status = 'complimentary',
         comp_note = btrim(p_note), comp_set_by = auth.uid(), comp_set_at = now(),
         grace_ends_at = null, locked_at = null, updated_at = now()
   where studio_id = p_studio_id;
  if not found then
    raise exception 'no such studio' using errcode = 'PT404';
  end if;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (p_studio_id, auth.uid(), 'platform.complimentary_set', 'platform_subscriptions',
          p_studio_id, jsonb_build_object('note', btrim(p_note)));
end $$;

create or replace function clear_studio_complimentary(p_studio_id uuid)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare v_trial timestamptz;
begin
  if not is_platform_admin() then
    raise exception 'only a platform admin can change this' using errcode = 'PT403';
  end if;
  -- Clearing starts a fresh 14-day trial from now, so a studio that was comped
  -- and is now expected to pay gets the same runway as a brand-new one.
  update platform_subscriptions
     set status = 'trialing',
         trial_ends_at = now() + interval '14 days',
         grace_ends_at = null, locked_at = null,
         comp_note = null, comp_set_by = null, comp_set_at = null,
         updated_at = now()
   where studio_id = p_studio_id and status = 'complimentary'
  returning trial_ends_at into v_trial;
  if v_trial is null then
    raise exception 'that studio is not complimentary' using errcode = 'PT409';
  end if;
  insert into audit_logs (studio_id, actor_user_id, action, entity_table, entity_id, after)
  values (p_studio_id, auth.uid(), 'platform.complimentary_cleared', 'platform_subscriptions',
          p_studio_id, jsonb_build_object('trial_ends_at', v_trial));
  return v_trial;
end $$;

revoke execute on function set_studio_complimentary(uuid, text)   from public, anon;
grant  execute on function set_studio_complimentary(uuid, text)   to authenticated, service_role;
revoke execute on function clear_studio_complimentary(uuid)       from public, anon;
grant  execute on function clear_studio_complimentary(uuid)       to authenticated, service_role;

-- ---- stripe_platform_handle re-issued: skip a complimentary studio ----------
create or replace function stripe_platform_handle(p_type text, p_obj jsonb)
returns text
language plpgsql security definer set search_path = public as $$
declare sub platform_subscriptions%rowtype; v_studio uuid; v_end timestamptz;
begin
  -- Resolved from OUR customer id, or from the metadata we set on our own
  -- checkout session. Both are ours: this is our account, not a connected one,
  -- so there is no tenant to be misattributed to somebody else's studio.
  v_studio := nullif(p_obj -> 'metadata' ->> 'studio_id', '')::uuid;
  if v_studio is null then
    select studio_id into v_studio from platform_subscriptions
     where stripe_customer_id = nullif(p_obj ->> 'customer', '')
        or stripe_subscription_id = nullif(p_obj ->> 'subscription', '')
        or stripe_subscription_id = nullif(p_obj ->> 'id', '');
  end if;
  if v_studio is null then
    return 'no_matching_studio';
  end if;
  select * into sub from platform_subscriptions where studio_id = v_studio;

  -- Decision 53: a complimentary studio is never billed by us. A stray Stripe
  -- event must not flip it off complimentary — ignore it and log it.
  if sub.status = 'complimentary' then
    return 'ignored_complimentary';
  end if;

  if p_type = 'checkout.session.completed' then
    update platform_subscriptions
       set status = 'active',
           stripe_customer_id = coalesce(p_obj ->> 'customer', stripe_customer_id),
           stripe_subscription_id = coalesce(nullif(p_obj ->> 'subscription',''), stripe_subscription_id),
           grace_ends_at = null, locked_at = null, updated_at = now()
     where studio_id = v_studio;
    return 'subscribed';

  elsif p_type = 'invoice.paid' then
    v_end := to_timestamp((p_obj -> 'lines' -> 'data' -> 0 -> 'period' ->> 'end')::bigint);
    -- Paying reinstates everything. The lock is a status, never a deletion, so
    -- there is nothing to restore — the studio simply stops being locked.
    update platform_subscriptions
       set status = 'active', current_period_end = coalesce(v_end, current_period_end),
           grace_ends_at = null, locked_at = null,
           stripe_customer_id = coalesce(p_obj ->> 'customer', stripe_customer_id),
           updated_at = now()
     where studio_id = v_studio;
    return 'active';

  elsif p_type = 'invoice.payment_failed' then
    update platform_subscriptions
       set status = case when status = 'locked' then 'locked' else 'past_due' end,
           grace_ends_at = coalesce(grace_ends_at, now() + interval '14 days'),
           updated_at = now()
     where studio_id = v_studio;
    -- Day one, immediately. The rest of the schedule is the daily sweep's.
    perform queue_platform_warning(v_studio, 1);
    return 'past_due';

  elsif p_type = 'customer.subscription.deleted' then
    update platform_subscriptions
       set status = 'cancelled', cancelled_at = now(), updated_at = now()
     where studio_id = v_studio;
    return 'cancelled';
  end if;

  return 'ignored';
end $$;

-- Matches the original (migration 046): revoke from client roles; it is called
-- only by the SECURITY DEFINER stripe_platform_webhook, so needs no client grant.
revoke execute on function stripe_platform_handle(text, jsonb) from public, anon, authenticated;

-- The anon surface is unchanged — exactly TWELVE pre-login functions.
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if n <> 12 then raise exception 'anon surface is % functions, expected exactly 12', n; end if;
end $$;
