-- =============================================================================
-- Migration 038: Stripe Connect Standard — the studio's members pay the studio
-- =============================================================================
-- Money moves member -> the studio's own Stripe account. Studiior never holds
-- it and takes no application fee, so there is no destination charge and no
-- transfer: Checkout runs directly ON the connected account.
--
-- HOW THE WEBHOOK AUTHENTICATES ITSELF. Every other write in this codebase goes
-- through RLS with a real session behind it. A webhook has no session and never
-- will, and RLS cannot express "Stripe said so". Rather than introduce a
-- service-role key that can do anything to any tenant, the signature is
-- verified HERE: the route hands over the raw body and the Stripe-Signature
-- header, and stripe_webhook() recomputes the HMAC itself before it will look
-- at the payload. The cryptography is the gate, exactly as it is for
-- resolve_checkin_code(), and the function can therefore be anon-callable
-- without being open.
--
-- That makes it the FOURTH pre-login surface. CLAUDE.md's advisor query should
-- expect studio_by_slug, studio_invite_preview, accept_studio_invite,
-- claim_member_account, member_invite_preview and now stripe_webhook.
--
-- TENANT RESOLUTION IS FROM THE `account` FIELD, NEVER METADATA. A Connect
-- event carries the connected account id at the top level, put there by Stripe.
-- Metadata is put there by us and travels inside the object, so an attacker who
-- could get any event delivered could name any studio in it. The account field
-- resolves the tenant; metadata is then CHECKED against it and the event is
-- rejected if the two disagree.
-- =============================================================================

create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- Configuration and secrets, mirroring the notification adapter
-- -----------------------------------------------------------------------------
create table if not exists stripe_config (
  key   text primary key,
  value text not null,
  note  text
);
alter table stripe_config enable row level security;
grant select on stripe_config to service_role;

insert into stripe_config (key, value, note) values
  ('api_version', '2026-08-26.dahlia',
   'The version the installed SDK pins, recorded so a handler written against '
   'one payload shape is not silently fed another. Bump this and the package '
   'together or not at all.'),
  ('signature_tolerance_seconds', '300',
   'How old a signature may be. Stripe''s own default. Stops a captured body '
   'being replayed days later with its original signature.'),
  ('livemode_expected', 'false',
   'Test mode. An event whose livemode does not match this is refused, so a live '
   'key pointed at a test database cannot quietly write real money into it.')
on conflict (key) do nothing;

create or replace function stripe_setting(p_key text) returns text
language sql stable security definer set search_path = public as $$
  select value from stripe_config where key = p_key
$$;

/**
 * The platform's own Stripe secret key, from Vault or a database setting.
 *
 * Never in the repo. Same two places RESEND_API_KEY lives, and the same
 * reasoning: a key in a migration is a key in git history forever.
 */
create or replace function stripe_secret(p_name text default 'STRIPE_SECRET_KEY')
returns text
language plpgsql stable security definer set search_path = public, vault as $$
declare v text;
begin
  begin
    select decrypted_secret into v from vault.decrypted_secrets
     where name = p_name limit 1;
  exception when others then
    v := null;
  end;
  return coalesce(nullif(v, ''),
                  nullif(current_setting('app.' || lower(p_name), true), ''));
end $$;

revoke execute on function stripe_setting(text) from public, anon, authenticated;
revoke execute on function stripe_secret(text) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Stripe's signature scheme, in SQL
--
--   Stripe-Signature: t=1492774577,v1=<hex hmac-sha256 of "t.payload">
--
-- Verified here rather than in the route so that the database never takes an
-- unverified payload from anybody, including from our own code.
-- -----------------------------------------------------------------------------
create or replace function verify_stripe_signature(
  p_payload text, p_signature text, p_secret text
) returns boolean
language plpgsql immutable set search_path = public as $$
declare
  v_ts        bigint;
  v_expected  text;
  v_part      text;
  v_tolerance int := coalesce(nullif(stripe_setting('signature_tolerance_seconds'), '')::int, 300);
  v_ok        boolean := false;
begin
  if p_payload is null or p_signature is null or p_secret is null then
    return false;
  end if;

  -- t=...
  select substring(part from 3) into v_ts
    from unnest(string_to_array(p_signature, ',')) part
   where part like 't=%' limit 1;
  if v_ts is null then
    return false;
  end if;

  -- Replay window. A body captured off the wire keeps its signature forever;
  -- this is what stops it being useful tomorrow.
  if abs(extract(epoch from now())::bigint - v_ts) > v_tolerance then
    return false;
  end if;

  -- extensions.hmac, schema-qualified. pgcrypto lives in `extensions` here and
  -- on hosted, and migration 032 settled that a SECURITY DEFINER function
  -- qualifies what it calls rather than widening its search_path to reach it.
  v_expected := encode(extensions.hmac(v_ts::text || '.' || p_payload, p_secret, 'sha256'), 'hex');

  -- Stripe may send several v1 signatures during a secret rotation; any one
  -- matching is a valid event. Compared as digests rather than as strings so
  -- the comparison does not return early on the first differing character.
  for v_part in
    select substring(part from 4) from unnest(string_to_array(p_signature, ',')) part
     where part like 'v1=%'
  loop
    if extensions.digest(v_part, 'sha256') = extensions.digest(v_expected, 'sha256') then
      v_ok := true;
    end if;
  end loop;

  return v_ok;
end $$;

revoke execute on function verify_stripe_signature(text, text, text)
  from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- OAuth onboarding
--
-- Standard Connect: the owner authorises us against their OWN Stripe account
-- and we keep the account id. Single-use, expiring state, the same shape as
-- studio_invites — an OAuth redirect is an unauthenticated GET and the state is
-- the only thing that ties it back to the person who started it.
-- -----------------------------------------------------------------------------
create table if not exists stripe_oauth_states (
  state      text primary key,
  studio_id  uuid not null references studios on delete cascade,
  created_by uuid references profiles on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 minutes',
  used_at    timestamptz
);
alter table stripe_oauth_states enable row level security;
grant select on stripe_oauth_states to service_role;

create or replace function begin_stripe_connect(p_studio_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v_state text;
begin
  -- Owner only. §9 gives connecting a payment processor to the owner alone:
  -- it is the studio's bank relationship, not a rota change.
  if not is_owner(p_studio_id) then
    raise exception 'only the studio owner can connect Stripe'
      using errcode = 'PT403';
  end if;

  v_state := encode(extensions.gen_random_bytes(24), 'hex');
  insert into stripe_oauth_states (state, studio_id, created_by)
  values (v_state, p_studio_id, auth.uid());
  return v_state;
end $$;

create or replace function complete_stripe_connect(p_state text, p_account_id text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare s stripe_oauth_states%rowtype;
begin
  select * into s from stripe_oauth_states
   where state = p_state and used_at is null and expires_at > now()
   for update;
  if not found then
    raise exception 'that connection link has expired — start again from Settings'
      using errcode = 'PT404';
  end if;

  -- Re-checked at the far end of the redirect, not just at the near end: the
  -- callback arrives as a fresh request and the person holding the state is not
  -- necessarily the person who minted it.
  if not is_owner(s.studio_id) then
    raise exception 'only the studio owner can connect Stripe'
      using errcode = 'PT403';
  end if;

  if p_account_id is null or p_account_id !~ '^acct_[A-Za-z0-9]+$' then
    raise exception 'that is not a Stripe account id' using errcode = 'PT400';
  end if;

  update stripe_oauth_states set used_at = now() where state = p_state;
  update studios set stripe_account_id = p_account_id, updated_at = now()
   where id = s.studio_id;
  return s.studio_id;
end $$;

revoke execute on function begin_stripe_connect(uuid) from public, anon, authenticated;
revoke execute on function complete_stripe_connect(text, text) from public, anon, authenticated;
grant execute on function begin_stripe_connect(uuid) to authenticated;
grant execute on function complete_stripe_connect(text, text) to authenticated;

-- =============================================================================
-- Handlers
--
-- Each takes the resolved studio and the Stripe object. None of them decides
-- which tenant it is acting on — that is settled once, in the dispatcher, from
-- the account field.
-- =============================================================================

/**
 * checkout.session.completed — the member has paid.
 *
 * price_cents is snapshotted from the session metadata, which the checkout
 * carried from the plan's price AT THE MOMENT the member agreed to it. Not
 * re-read from membership_plans here: §7.1 is that editing a plan never
 * reprices anyone already on it, and reading the plan at webhook time would
 * reprice everyone whose payment landed after an edit.
 */
create or replace function stripe_handle_checkout_completed(
  p_studio_id uuid, p_obj jsonb
) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_kind      text := p_obj -> 'metadata' ->> 'kind';
  v_member    uuid := nullif(p_obj -> 'metadata' ->> 'member_id', '')::uuid;
  v_plan      uuid := nullif(p_obj -> 'metadata' ->> 'plan_id', '')::uuid;
  v_booking   uuid := nullif(p_obj -> 'metadata' ->> 'booking_id', '')::uuid;
  v_snapshot  int  := nullif(p_obj -> 'metadata' ->> 'price_cents', '')::int;
  v_currency  char(3) := upper(coalesce(p_obj ->> 'currency', 'usd'));
  v_amount    int  := coalesce((p_obj ->> 'amount_total')::int, v_snapshot, 0);
  plan        membership_plans%rowtype;
  v_ms        uuid;
  v_bal       int;
begin
  -- The member named in metadata must belong to the studio the ACCOUNT field
  -- resolved to. Metadata is ours but it travels through Stripe, and a member
  -- id from another tenant is the one thing that would break isolation here.
  if v_member is not null and not exists (
    select 1 from members where id = v_member and studio_id = p_studio_id
  ) then
    raise exception 'that member does not belong to this studio'
      using errcode = 'PT403';
  end if;

  -- ---- a drop-in: the held seat becomes a real booking -----------------------
  if v_kind = 'dropin' then
    update bookings
       set status = 'booked'
     where id = v_booking
       and studio_id = p_studio_id
       and status = 'pending_payment';
    -- No row means the sweep already took the seat back. The money is still
    -- theirs and the payment row records it; the studio refunds or credits it.
    -- Flipping a cancelled booking back to booked would put someone into a
    -- class that has since been given to the waitlist.

    update payments
       set status = 'succeeded', paid_at = now(),
           stripe_payment_intent_id = p_obj ->> 'payment_intent',
           amount_cents = v_amount, currency = v_currency, updated_at = now()
     where booking_id = v_booking and studio_id = p_studio_id and status = 'pending';

    if not found then
      insert into payments (studio_id, member_id, booking_id, amount_cents, currency,
                            status, description, stripe_payment_intent_id, paid_at)
      values (p_studio_id, v_member, v_booking, v_amount, v_currency,
              'succeeded', 'Drop-in class', p_obj ->> 'payment_intent', now());
    end if;
    return 'dropin_paid';
  end if;

  -- ---- a plan or a pack ------------------------------------------------------
  select * into plan from membership_plans where id = v_plan and studio_id = p_studio_id;
  if not found then
    raise exception 'no such plan for this studio' using errcode = 'PT404';
  end if;

  insert into memberships (
    studio_id, member_id, plan_id, status, price_cents, currency, starts_on,
    credits_remaining, expires_on, auto_renew,
    stripe_customer_id, stripe_subscription_id
  ) values (
    p_studio_id, v_member, plan.id,
    -- Cast. An unadorned CASE here yields text, and text into a
    -- membership_status column fails at RUNTIME rather than at create time —
    -- the same trap cancel_booking() fell into in migration 025.
    (case when plan.type = 'trial' then 'trialing' else 'active' end)::membership_status,
    coalesce(v_snapshot, plan.price_cents),          -- the snapshot, §7.1
    coalesce(nullif(plan.currency, ''), v_currency),
    current_date,
    case when plan.type = 'class_pack' then plan.credits else plan.credits_per_period end,
    case when plan.type = 'class_pack' and plan.validity_days is not null
         then current_date + plan.validity_days end,
    plan.type = 'recurring',
    p_obj ->> 'customer',
    nullif(p_obj ->> 'subscription', '')
  ) returning id into v_ms;

  -- §6: a pack's classes arrive as ledger rows, never as a number typed into
  -- credits_remaining. The cache above is written in the same transaction.
  if plan.type = 'class_pack' and coalesce(plan.credits, 0) > 0 then
    select coalesce(sum(delta), 0) into v_bal
      from credit_ledger where studio_id = p_studio_id and member_id = v_member;
    insert into credit_ledger (studio_id, member_id, membership_id, delta, reason,
                               balance_after, expires_at)
    values (p_studio_id, v_member, v_ms, plan.credits, 'purchase',
            v_bal + plan.credits,
            case when plan.validity_days is not null
                 then (current_date + plan.validity_days + 1)::timestamptz end);
  end if;

  insert into payments (studio_id, member_id, membership_id, amount_cents, currency,
                        status, description, stripe_payment_intent_id, paid_at)
  values (p_studio_id, v_member, v_ms, v_amount, v_currency, 'succeeded',
          plan.name, p_obj ->> 'payment_intent', now());

  insert into membership_events (studio_id, membership_id, type, to_status, metadata)
  values (p_studio_id, v_ms, 'created',
          case when plan.type = 'trial' then 'trialing' else 'active' end::membership_status,
          jsonb_build_object('stripe_session', p_obj ->> 'id'));

  return 'membership_created';
end $$;

/** invoice.paid — §7.2. The period advances and the allowance is granted. */
create or replace function stripe_handle_invoice_paid(p_studio_id uuid, p_obj jsonb)
returns text
language plpgsql security definer set search_path = public as $$
declare
  ms   memberships%rowtype;
  plan membership_plans%rowtype;
  v_start timestamptz; v_end timestamptz; v_bal int;
begin
  select * into ms from memberships
   where studio_id = p_studio_id
     and stripe_subscription_id = nullif(p_obj ->> 'subscription', '');
  if not found then
    return 'no_matching_membership';
  end if;
  select * into plan from membership_plans where id = ms.plan_id;

  v_start := to_timestamp((p_obj -> 'lines' -> 'data' -> 0 -> 'period' ->> 'start')::bigint);
  v_end   := to_timestamp((p_obj -> 'lines' -> 'data' -> 0 -> 'period' ->> 'end')::bigint);

  update memberships
     set status = 'active',
         current_period_start = coalesce(v_start, current_period_start),
         current_period_end   = coalesce(v_end, current_period_end),
         renews_on            = coalesce(v_end::date, renews_on),
         -- §7.2: nothing is granted optimistically. The allowance lands when
         -- the money does, which is here.
         credits_remaining    = case when plan.type = 'recurring'
                                     then plan.credits_per_period
                                     else credits_remaining end,
         credits_reset_at     = coalesce(v_end, credits_reset_at)
   where id = ms.id;

  if plan.type = 'recurring' and plan.credits_per_period is not null then
    select coalesce(sum(delta), 0) into v_bal
      from credit_ledger where studio_id = p_studio_id and member_id = ms.member_id;
    insert into credit_ledger (studio_id, member_id, membership_id, delta, reason,
                               balance_after, expires_at)
    values (p_studio_id, ms.member_id, ms.id, plan.credits_per_period, 'period_grant',
            v_bal + plan.credits_per_period, v_end);
  end if;

  insert into payments (studio_id, member_id, membership_id, amount_cents, currency,
                        status, description, stripe_invoice_id, paid_at)
  values (p_studio_id, ms.member_id, ms.id, coalesce((p_obj ->> 'amount_paid')::int, 0),
          upper(coalesce(p_obj ->> 'currency', ms.currency)), 'succeeded',
          coalesce(plan.name, 'Membership'), p_obj ->> 'id', now());

  insert into membership_events (studio_id, membership_id, type, from_status, to_status)
  values (p_studio_id, ms.id, 'renewed', ms.status, 'active');

  return 'renewed';
end $$;

/**
 * invoice.payment_failed — §7.3 and Decision 4.
 *
 * past_due, and that is all. The grace arithmetic already lives in
 * book_class(), which lets a past_due member book until current_period_end +
 * payment_grace_days and refuses after: blocked means NO NEW BOOKINGS and
 * existing bookings stand, because cancelling classes somebody already booked
 * over a bank's decision is how you lose a member who did nothing wrong.
 *
 * queue_payment_failed() has existed since migration 031 with nothing calling
 * it. This is its caller.
 */
create or replace function stripe_handle_invoice_failed(p_studio_id uuid, p_obj jsonb)
returns text
language plpgsql security definer set search_path = public as $$
declare ms memberships%rowtype;
begin
  select * into ms from memberships
   where studio_id = p_studio_id
     and stripe_subscription_id = nullif(p_obj ->> 'subscription', '');
  if not found then
    return 'no_matching_membership';
  end if;

  update memberships set status = 'past_due' where id = ms.id;

  insert into payments (studio_id, member_id, membership_id, amount_cents, currency,
                        status, description, stripe_invoice_id,
                        failure_code, failure_message, attempt_count)
  values (p_studio_id, ms.member_id, ms.id, coalesce((p_obj ->> 'amount_due')::int, 0),
          upper(coalesce(p_obj ->> 'currency', ms.currency)), 'failed',
          'Membership payment', p_obj ->> 'id',
          p_obj -> 'last_finalization_error' ->> 'code',
          p_obj -> 'last_finalization_error' ->> 'message',
          coalesce((p_obj ->> 'attempt_count')::int, 1));

  insert into membership_events (studio_id, membership_id, type, from_status, to_status)
  values (p_studio_id, ms.id, 'payment_failed', ms.status, 'past_due');

  perform queue_payment_failed(ms.id);
  return 'past_due';
end $$;

/** customer.subscription.updated / .deleted — status and period follow Stripe. */
create or replace function stripe_handle_subscription_changed(
  p_studio_id uuid, p_obj jsonb, p_deleted boolean
) returns text
language plpgsql security definer set search_path = public as $$
declare ms memberships%rowtype; v_status membership_status; v_end timestamptz;
begin
  select * into ms from memberships
   where studio_id = p_studio_id and stripe_subscription_id = p_obj ->> 'id';
  if not found then
    return 'no_matching_membership';
  end if;

  v_end := to_timestamp(nullif(p_obj ->> 'current_period_end', '')::bigint);

  v_status := case
    when p_deleted then 'cancelled'
    else case p_obj ->> 'status'
           when 'trialing' then 'trialing'
           when 'active'   then 'active'
           when 'past_due' then 'past_due'
           when 'unpaid'   then 'past_due'
           when 'canceled' then 'cancelled'
           else ms.status
         end::membership_status
  end;

  update memberships
     set status = v_status,
         current_period_end = coalesce(v_end, current_period_end),
         renews_on = coalesce(v_end::date, renews_on),
         -- §7.5: cancel at period end is the default, and access continues to
         -- the end of the period they paid for.
         cancel_at = case when coalesce((p_obj ->> 'cancel_at_period_end')::boolean, false)
                          then coalesce(v_end::date, cancel_at) else null end,
         cancelled_at = case when p_deleted then now() else cancelled_at end
   where id = ms.id;

  if v_status is distinct from ms.status then
    insert into membership_events (studio_id, membership_id, type, from_status, to_status)
    values (p_studio_id, ms.id,
            case when p_deleted then 'cancelled' else 'updated' end, ms.status, v_status);
  end if;

  return v_status::text;
end $$;

/** charge.refunded — partial or full, decided by the amounts Stripe reports. */
create or replace function stripe_handle_charge_refunded(p_studio_id uuid, p_obj jsonb)
returns text
language plpgsql security definer set search_path = public as $$
declare v_refunded int; v_amount int; v_status payment_status; n int;
begin
  v_refunded := coalesce((p_obj ->> 'amount_refunded')::int, 0);
  v_amount   := coalesce((p_obj ->> 'amount')::int, 0);
  v_status   := case when v_refunded >= v_amount and v_amount > 0
                     then 'refunded' else 'partially_refunded' end;

  update payments
     set status = v_status, updated_at = now(),
         stripe_charge_id = coalesce(stripe_charge_id, p_obj ->> 'id')
   where studio_id = p_studio_id
     and (stripe_payment_intent_id = nullif(p_obj ->> 'payment_intent', '')
          or stripe_charge_id = p_obj ->> 'id');
  get diagnostics n = row_count;

  return case when n = 0 then 'no_matching_payment' else v_status::text end;
end $$;

-- =============================================================================
-- The dispatcher — the only new pre-login surface
-- =============================================================================
/**
 * Verify, resolve the tenant, deduplicate, dispatch.
 *
 * Anon-callable, because a webhook arrives with no session and never will. It
 * is not open: it recomputes the HMAC over the raw body before it reads a
 * single field, so a caller who cannot produce a valid Stripe signature gets
 * nothing at all. Same shape as resolve_checkin_code() — the cryptography is
 * the gate rather than the caller's identity.
 *
 * IDEMPOTENCY is the insert into stripe_events, whose primary key is Stripe's
 * own event id. A replay conflicts, inserts nothing, and returns 'duplicate'
 * without reaching a handler. Stripe retries for days on any non-2xx, so this
 * is a certainty rather than a precaution.
 */
create or replace function stripe_webhook(p_payload text, p_signature text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_secret  text;
  e         jsonb;
  v_id      text;
  v_type    text;
  v_account text;
  v_obj     jsonb;
  v_studio  uuid;
  v_meta    uuid;
  v_result  text;
  n         int;
begin
  v_secret := stripe_secret('STRIPE_WEBHOOK_SECRET');
  if v_secret is null then
    -- A clear refusal, not a crash. Same reasoning as a missing Resend key:
    -- the operator needs to be told which secret is absent.
    raise exception 'STRIPE_WEBHOOK_SECRET is not configured'
      using errcode = 'PT503',
            hint = 'Set it in Vault, or as app.stripe_webhook_secret. It is '
                   'deliberately not in the repo.';
  end if;

  if not verify_stripe_signature(p_payload, p_signature, v_secret) then
    raise exception 'bad Stripe signature' using errcode = 'PT401';
  end if;

  e        := p_payload::jsonb;
  v_id     := e ->> 'id';
  v_type   := e ->> 'type';
  v_account:= e ->> 'account';
  v_obj    := e -> 'data' -> 'object';

  if v_id is null or v_type is null then
    raise exception 'not a Stripe event' using errcode = 'PT400';
  end if;

  -- Test mode means test mode. A live event arriving here would be real money
  -- being written into a database that is not ready for it.
  if coalesce((e ->> 'livemode')::boolean, false)
     <> coalesce(stripe_setting('livemode_expected')::boolean, false) then
    raise exception 'livemode mismatch: this endpoint expects %',
      stripe_setting('livemode_expected') using errcode = 'PT400';
  end if;

  -- A Connect event carries the connected account at the top level. No account
  -- means it is an event on OUR OWN platform account, which is Phase B and has
  -- its own endpoint; it is recorded and ignored rather than guessed at.
  if v_account is null then
    insert into stripe_events (id, type, payload, error)
    values (v_id, v_type, e, 'platform event delivered to the connect endpoint')
    on conflict (id) do nothing;
    return jsonb_build_object('status', 'not_a_connect_event', 'type', v_type);
  end if;

  select id into v_studio from studios where stripe_account_id = v_account;

  -- Recorded either way, so an event for an account we do not know is visible
  -- rather than silently dropped — but NOT processed and never guessed at from
  -- metadata, which is ours and travels inside the object where a forged event
  -- could name any studio it liked.
  insert into stripe_events (id, studio_id, stripe_account_id, type, payload, error)
  values (v_id, v_studio, v_account, v_type, e,
          case when v_studio is null then 'no studio for this connected account' end)
  on conflict (id) do nothing;
  get diagnostics n = row_count;

  if n = 0 then
    return jsonb_build_object('status', 'duplicate', 'id', v_id);
  end if;
  if v_studio is null then
    return jsonb_build_object('status', 'unknown_account', 'account', v_account);
  end if;

  -- If the object also names a studio, it must be the same one. Belt and
  -- braces: the account field already decided, and this catches a session
  -- created against the wrong account before it can write anywhere.
  v_meta := nullif(v_obj -> 'metadata' ->> 'studio_id', '')::uuid;
  if v_meta is not null and v_meta <> v_studio then
    update stripe_events
       set error = 'metadata studio_id does not match the connected account',
           processed_at = now()
     where id = v_id;
    return jsonb_build_object('status', 'tenant_mismatch', 'id', v_id);
  end if;

  v_result := case v_type
    when 'checkout.session.completed'      then stripe_handle_checkout_completed(v_studio, v_obj)
    when 'invoice.paid'                    then stripe_handle_invoice_paid(v_studio, v_obj)
    when 'invoice.payment_failed'          then stripe_handle_invoice_failed(v_studio, v_obj)
    when 'customer.subscription.updated'   then stripe_handle_subscription_changed(v_studio, v_obj, false)
    when 'customer.subscription.deleted'   then stripe_handle_subscription_changed(v_studio, v_obj, true)
    when 'charge.refunded'                 then stripe_handle_charge_refunded(v_studio, v_obj)
    else 'ignored'
  end;

  update stripe_events set processed_at = now() where id = v_id;
  return jsonb_build_object('status', 'processed', 'id', v_id,
                            'type', v_type, 'result', v_result);
end $$;

-- The fourth pre-login surface, and the only one that is a WRITE. Everything it
-- can do is behind the HMAC check at the top of it.
revoke execute on function stripe_webhook(text, text) from public;
grant execute on function stripe_webhook(text, text) to anon, authenticated, service_role;

do $$
declare f record; n int := 0;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p
     join pg_namespace nsp on nsp.oid = p.pronamespace
    where nsp.nspname = 'public'
      and p.proname in ('stripe_handle_checkout_completed','stripe_handle_invoice_paid',
                        'stripe_handle_invoice_failed','stripe_handle_subscription_changed',
                        'stripe_handle_charge_refunded')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    n := n + 1;
  end loop;
  if n <> 5 then
    raise exception 'expected 5 stripe handlers to close, closed %', n;
  end if;
  raise notice 'migration 038: closed % stripe handlers to client roles', n;
end $$;
