-- Migration 176 — Decision 40 Part A: Xendit adapter.
--
-- Xendit is the second online payment provider under Decision 16: a Xendit
-- payment activates a membership / grants a pack through the SAME
-- activate_purchase() a cash or Stripe payment does. Studiior INITIATES every
-- payment (a PAY Payment Session stamped with our own ids) and learns the
-- outcome from Xendit's x-callback-token callback; it never scrapes Xendit.
--
-- PART A ONLY — one-time purchases (non-recurring plans: class_pack / drop_in).
-- Subscriptions / auto-charge are Part B and are NOT built here.
--
-- The provider secrets are AES-256-GCM encrypted in the Next runtime under
-- INTEGRATIONS_ENCRYPTION_KEY (env only, never in the DB / repo / logs). The DB
-- holds only ciphertext + a sha256 of the callback token. See Decision 40.

-- =============================================================================
-- 1. studio_payment_providers — one row per studio per provider. Owner-only.
-- =============================================================================
create table studio_payment_providers (
  studio_id                uuid not null references studios on delete cascade,
  provider                 payment_provider not null,
  secret_key_ciphertext    text not null,   -- AES-GCM(v1.iv‖tag‖ct), env key
  callback_token_ciphertext text not null,  -- AES-GCM, kept for parity/rotation
  callback_token_sha256    text not null,   -- what the anon webhook verifies in SQL
  key_last4                text,
  test_mode                boolean not null default true,
  connected_at             timestamptz not null default now(),
  connected_by             uuid references profiles on delete set null,
  last_verified_at         timestamptz,
  updated_at               timestamptz not null default now(),
  primary key (studio_id, provider)
);
create trigger studio_payment_providers_updated before update on studio_payment_providers
  for each row execute function set_updated_at();

alter table studio_payment_providers enable row level security;

-- Ciphertext is readable/writable ONLY by an owner-role session of that studio.
-- (is_owner can be NULL for a non-member; in an RLS USING/WITH CHECK NULL denies,
-- which is safe — unlike a plpgsql `if not is_owner()` guard, migration 020.)
create policy xpp_owner on studio_payment_providers
  for all using (is_owner(studio_id)) with check (is_owner(studio_id));

grant select, insert, update, delete on studio_payment_providers to authenticated;
grant all on studio_payment_providers to service_role;

-- =============================================================================
-- 2. xendit_purchases — the pending-intent + session tracker. There is no
--    `purchases` table and `payments` is money that MOVED (written on success),
--    so a pending online intent lives here. Its id is the reference_id we send
--    Xendit, and it is what the member's /purchase/{id} poll screen reads.
-- =============================================================================
create table xendit_purchases (
  id                 uuid primary key default gen_random_uuid(),
  studio_id          uuid not null references studios on delete cascade,
  member_id          uuid not null references members on delete cascade,
  plan_id            uuid not null references membership_plans on delete restrict,
  amount_cents       int not null,
  currency           char(3) not null,
  status             text not null default 'pending'
                       check (status in ('pending','succeeded','failed','expired','cancelled')),
  payment_session_id text,
  payment_link_url   text,
  xendit_payment_id  text,
  failure_reason     text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  completed_at       timestamptz
);
create index on xendit_purchases (studio_id, status, created_at);
create index on xendit_purchases (member_id, created_at desc);
create trigger xendit_purchases_updated before update on xendit_purchases
  for each row execute function set_updated_at();

alter table xendit_purchases enable row level security;

-- A member reads their own purchases (the poll screen); staff read the studio's.
create policy xpur_member_self on xendit_purchases
  for select using (
    exists (select 1 from members m where m.id = xendit_purchases.member_id and m.user_id = auth.uid())
  );
create policy xpur_staff_read on xendit_purchases
  for select using (is_manager_up(studio_id));

-- No client INSERT/UPDATE: every write goes through the SECURITY DEFINER
-- functions below (amount is set from the plan, never from client input).
grant select on xendit_purchases to authenticated;
grant all on xendit_purchases to service_role;

-- =============================================================================
-- 3. xendit_events — the idempotency ledger. Stored only AFTER token
--    verification. Unique on event_id so a replay is a no-op. Closed to clients.
-- =============================================================================
create table xendit_events (
  id           uuid primary key default gen_random_uuid(),
  studio_id    uuid references studios on delete cascade,
  event_id     text not null unique,
  event_type   text,
  payload      jsonb not null,
  received_at  timestamptz not null default now(),
  processed_at timestamptz,
  purchase_id  uuid references xendit_purchases on delete set null,
  error        text
);
create index on xendit_events (studio_id, received_at desc);

alter table xendit_events enable row level security;
-- No policies: clients see nothing. The webhook writes it as SECURITY DEFINER.
grant all on xendit_events to service_role;

-- =============================================================================
-- 4. Failure/expiry notice template (a data row — render_notification reads the
--    body from here; an unlisted template defaults to "send" in notification_wanted).
-- =============================================================================
insert into notification_templates (key, subject, text_body, html_body, note) values
  ('xendit_purchase_failed',
   'Your payment didn''t go through',
   E'Hi {first_name},\n\nYour payment for {plan_name} at {studio_name} didn''t go through, so nothing was charged and no plan was added.\n\nYou can try again from the app, or have a word with the studio.\n\n— {studio_name}',
   '<p>Hi {first_name},</p><p>Your payment for <strong>{plan_name}</strong> at {studio_name} didn''t go through, so nothing was charged and no plan was added.</p><p>You can try again from the app, or have a word with the studio.</p><p>— {studio_name}</p>',
   'Decision 40: a Xendit one-time purchase failed or its session expired.')
on conflict (key) do nothing;

-- =============================================================================
-- 5. xendit_checkout_context — the purchase path's read of the secret. Returns
--    ciphertext + test_mode to an authenticated MEMBER of that studio. The
--    ciphertext is useless without the env key (server runtime only), so this
--    respects the no-service-role-client rule.
-- =============================================================================
create function xendit_checkout_context(p_studio_id uuid)
returns table(secret_key_ciphertext text, test_mode boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from members m where m.studio_id = p_studio_id and m.user_id = auth.uid()) then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;
  return query
    select spp.secret_key_ciphertext, spp.test_mode
      from studio_payment_providers spp
     where spp.studio_id = p_studio_id and spp.provider = 'xendit';
end $$;

revoke execute on function xendit_checkout_context(uuid) from public, anon;
grant  execute on function xendit_checkout_context(uuid) to authenticated, service_role;

-- =============================================================================
-- 6. xendit_begin_purchase — a member starts a one-time purchase. Validates the
--    plan (public, active, one-time), snapshots the amount FROM THE PLAN (never
--    client input), creates the pending row, returns its id + amount + currency.
-- =============================================================================
create function xendit_begin_purchase(p_studio_id uuid, p_plan_id uuid)
returns table(purchase_id uuid, amount_cents int, currency char(3))
language plpgsql security definer set search_path = public as $$
declare v_member uuid; mp membership_plans%rowtype; v_id uuid;
begin
  select id into v_member from members where studio_id = p_studio_id and user_id = auth.uid();
  if v_member is null then
    raise exception 'you are not a member of that studio' using errcode = 'PT403';
  end if;
  if not exists (select 1 from studio_payment_providers where studio_id = p_studio_id and provider = 'xendit') then
    raise exception 'this studio is not set up to take online payments' using errcode = 'PT409';
  end if;

  select * into mp from membership_plans
   where id = p_plan_id and studio_id = p_studio_id and visibility = 'public' and status = 'active';
  if mp.id is null then
    raise exception 'that plan is not on sale' using errcode = 'PT404';
  end if;
  -- Part A is one-time only. A recurring plan is a subscription (auto-charge is
  -- Part B) and must not be bought as a one-off here.
  if mp.type not in ('class_pack', 'drop_in') then
    raise exception 'that plan is not a one-time purchase' using errcode = 'PT422';
  end if;

  insert into xendit_purchases (studio_id, member_id, plan_id, amount_cents, currency)
  values (p_studio_id, v_member, p_plan_id, mp.price_cents, mp.currency)
  returning id into v_id;

  return query select v_id, mp.price_cents, mp.currency;
end $$;

revoke execute on function xendit_begin_purchase(uuid, uuid) from public, anon;
grant  execute on function xendit_begin_purchase(uuid, uuid) to authenticated, service_role;

-- =============================================================================
-- 7. xendit_attach_session — store the Xendit session id + link on the member's
--    own pending purchase (called by the buy action after creating the session).
-- =============================================================================
create function xendit_attach_session(p_purchase_id uuid, p_session_id text, p_link_url text)
returns void
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update xendit_purchases xp
     set payment_session_id = p_session_id, payment_link_url = p_link_url, updated_at = now()
   where xp.id = p_purchase_id
     and xp.status = 'pending'
     and exists (select 1 from members m where m.id = xp.member_id and m.user_id = auth.uid());
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'that purchase is not yours to attach' using errcode = 'PT403';
  end if;
end $$;

revoke execute on function xendit_attach_session(uuid, text, text) from public, anon;
grant  execute on function xendit_attach_session(uuid, text, text) to authenticated, service_role;

-- =============================================================================
-- 8. xendit_activate_success_internal — the ONE place a successful Xendit
--    purchase is applied. Idempotent (skips an already-succeeded purchase),
--    grants through activate_purchase (seat cap NOT enforced — money captured,
--    the Stripe-checkout rule), writes the payments row, flips the purchase.
--    Called only from other SECURITY DEFINER functions (webhook, owner apply);
--    closed to every client role.
-- =============================================================================
create function xendit_activate_success_internal(p_purchase_id uuid, p_payment_id text)
returns text
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype; v_ms uuid;
begin
  select * into p from xendit_purchases where id = p_purchase_id for update;
  if p.id is null then return 'unknown_purchase'; end if;
  if p.status = 'succeeded' then return 'already_succeeded'; end if;

  v_ms := activate_purchase(p.studio_id, p.member_id, p.plan_id, p.amount_cents, p.currency,
                            null, null, false);

  insert into payments (studio_id, member_id, membership_id, amount_cents, currency,
                        status, provider, reference, description, paid_at)
  select p.studio_id, p.member_id, v_ms, p.amount_cents, p.currency, 'succeeded', 'xendit',
         nullif(p_payment_id, ''), mp.name, now()
    from membership_plans mp where mp.id = p.plan_id;

  update xendit_purchases
     set status = 'succeeded', xendit_payment_id = nullif(p_payment_id, ''),
         completed_at = now(), failure_reason = null, updated_at = now()
   where id = p_purchase_id;

  return 'activated';
end $$;

revoke execute on function xendit_activate_success_internal(uuid, text) from public, anon, authenticated;
grant  execute on function xendit_activate_success_internal(uuid, text) to service_role;

-- Internal helper: mark a purchase failed/expired and notify the member once.
create function xendit_fail_purchase_internal(p_purchase_id uuid, p_status text, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype;
begin
  select * into p from xendit_purchases where id = p_purchase_id for update;
  if p.id is null or p.status in ('succeeded') then return; end if;

  update xendit_purchases
     set status = p_status, failure_reason = p_reason, completed_at = now(), updated_at = now()
   where id = p_purchase_id and status = 'pending';

  perform queue_notification(
    p.studio_id, p.member_id, 'xendit_purchase_failed',
    jsonb_build_object('plan_name', (select name from membership_plans where id = p.plan_id)),
    'xendit_failed:' || p_purchase_id::text);
end $$;

revoke execute on function xendit_fail_purchase_internal(uuid, text, text) from public, anon, authenticated;
grant  execute on function xendit_fail_purchase_internal(uuid, text, text) to service_role;

-- =============================================================================
-- 9. xendit_webhook — the TWELFTH pre-login (anon) surface. The stripe_webhook
--    shape: the credential (x-callback-token) is an argument, verified in SQL,
--    so the anon RPC is not an independently-exploitable "activate" surface.
-- =============================================================================
create function xendit_webhook(p_event jsonb, p_token text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  d jsonb := p_event -> 'data';
  v_ref text := d ->> 'reference_id';
  v_event text := p_event ->> 'event';
  v_status text := upper(coalesce(d ->> 'status', ''));
  v_payment_id text := d ->> 'payment_id';
  v_amount numeric := nullif(d ->> 'amount', '')::numeric;
  v_currency text := upper(nullif(d ->> 'currency', ''));
  p xendit_purchases%rowtype;
  v_hash text; v_event_id text; n int; v_success boolean; v_failure boolean;
begin
  -- Resolve OUR purchase from reference_id. Unknown → do nothing, store nothing.
  if v_ref is null then return jsonb_build_object('status', 'ignored', 'reason', 'no_reference'); end if;
  select * into p from xendit_purchases where id = v_ref::uuid;
  if p.id is null then return jsonb_build_object('status', 'ignored', 'reason', 'unknown_reference'); end if;

  -- Verify the callback token IN SQL against the studio's stored hash BEFORE
  -- storing or processing anything. Mismatch → PT401 (route maps to 401), and
  -- no event row is written.
  select callback_token_sha256 into v_hash
    from studio_payment_providers where studio_id = p.studio_id and provider = 'xendit';
  if v_hash is null
     or p_token is null
     or encode(digest(p_token, 'sha256'), 'hex') <> v_hash then
    raise exception 'bad Xendit callback token' using errcode = 'PT401';
  end if;

  -- Idempotency: store the event, unique on event_id. A replay inserts nothing.
  v_event_id := coalesce(nullif(v_payment_id, ''), nullif(p_event ->> 'id', ''),
                         encode(digest(p_event::text, 'sha256'), 'hex'));
  insert into xendit_events (studio_id, event_id, event_type, payload, purchase_id)
  values (p.studio_id, v_event_id, v_event, p_event, p.id)
  on conflict (event_id) do nothing;
  get diagnostics n = row_count;
  if n = 0 then return jsonb_build_object('status', 'duplicate'); end if;

  -- Success is decided by data.status = 'SUCCEEDED' (robust to the event-name
  -- disagreement between docs pages: payment.succeeded vs payment.capture).
  v_success := v_status = 'SUCCEEDED' or v_event in ('payment.succeeded', 'payment.capture');
  v_failure := v_event = 'payment.failure' or v_status in ('FAILED', 'FAILURE', 'VOIDED', 'EXPIRED', 'CANCELED', 'CANCELLED');

  if v_success then
    -- Belt on the credential: validate amount/currency when the payload carries
    -- them (Xendit amount is MAJOR units — pesos — so × 100 to cents).
    if v_amount is not null and round(v_amount * 100) <> p.amount_cents then
      update xendit_events set error = 'amount_mismatch', processed_at = now() where event_id = v_event_id;
      return jsonb_build_object('status', 'refused', 'reason', 'amount_mismatch');
    end if;
    if v_currency is not null and v_currency <> upper(p.currency) then
      update xendit_events set error = 'currency_mismatch', processed_at = now() where event_id = v_event_id;
      return jsonb_build_object('status', 'refused', 'reason', 'currency_mismatch');
    end if;

    perform xendit_activate_success_internal(p.id, v_payment_id);
    update xendit_events set processed_at = now() where event_id = v_event_id;
    return jsonb_build_object('status', 'processed', 'outcome', 'succeeded');

  elsif v_failure then
    perform xendit_fail_purchase_internal(p.id, 'failed', coalesce(d ->> 'failure_code', v_event));
    update xendit_events set processed_at = now() where event_id = v_event_id;
    return jsonb_build_object('status', 'processed', 'outcome', 'failed');
  end if;

  update xendit_events set processed_at = now() where event_id = v_event_id;
  return jsonb_build_object('status', 'ignored', 'reason', 'non_terminal');
end $$;

revoke execute on function xendit_webhook(jsonb, text) from public;
grant  execute on function xendit_webhook(jsonb, text) to anon, authenticated, service_role;

-- =============================================================================
-- 10. xendit_apply_session — owner-triggered reconcile of ONE pending purchase
--     after the owner's server has asked Xendit GET /sessions/{id}. Guarded to
--     managers-up of that purchase's studio.
-- =============================================================================
create function xendit_apply_session(p_purchase_id uuid, p_session_status text, p_payment_id text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare p xendit_purchases%rowtype; v_st text := upper(coalesce(p_session_status, ''));
begin
  select * into p from xendit_purchases where id = p_purchase_id;
  if p.id is null then raise exception 'no such purchase' using errcode = 'PT404'; end if;
  if not is_manager_up(p.studio_id) then
    raise exception 'that is not your studio''s purchase' using errcode = 'PT403';
  end if;

  if v_st = 'COMPLETED' then
    perform xendit_activate_success_internal(p.id, p_payment_id);
    return jsonb_build_object('status', 'processed', 'outcome', 'succeeded');
  elsif v_st in ('EXPIRED', 'CANCELED', 'CANCELLED') then
    perform xendit_fail_purchase_internal(p.id,
      case when v_st = 'EXPIRED' then 'expired' else 'cancelled' end, v_st);
    return jsonb_build_object('status', 'processed', 'outcome', lower(v_st));
  end if;
  return jsonb_build_object('status', 'ignored', 'reason', 'still_active');
end $$;

revoke execute on function xendit_apply_session(uuid, text, text) from public, anon;
grant  execute on function xendit_apply_session(uuid, text, text) to authenticated, service_role;

-- =============================================================================
-- 11. xendit_reconcile_sweep — the automatic backstop (pg_cron, service context).
--     It does NOT ask Xendit (a pg_cron SQL fn has neither the env key to
--     decrypt the secret nor a way to Basic-auth an HTTPS GET). It marks a
--     purchase pending beyond a generous window as expired and notifies the
--     member. This is SAFE because a late/retried success callback still
--     activates: the webhook honours any not-yet-succeeded purchase, not only a
--     pending one. See Decision 40 for why the automatic ask-Xendit is owner-
--     triggered instead of cross-tenant.
-- =============================================================================
create function xendit_reconcile_sweep(p_now timestamptz default now())
returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; v_expired int := 0;
begin
  if not is_service_context() then
    raise exception 'the xendit reconcile sweep is a background job' using errcode = 'PT403';
  end if;

  for r in
    select id, studio_id from xendit_purchases
     where status = 'pending' and created_at < p_now - interval '2 hours'
  loop
    perform xendit_fail_purchase_internal(r.id, 'expired', 'reconcile_timeout');
    v_expired := v_expired + 1;
  end loop;

  insert into audit_logs (studio_id, action, entity_table, entity_id, after)
  select s.id, 'xendit.reconcile_swept', 'xendit_purchases', null,
         jsonb_build_object('expired', v_expired, 'at', p_now)
    from studios s
   where exists (select 1 from studio_payment_providers spp
                  where spp.studio_id = s.id and spp.provider = 'xendit')
   limit 1;

  return jsonb_build_object('expired', v_expired);
end $$;

revoke execute on function xendit_reconcile_sweep(timestamptz) from public, anon, authenticated;
grant  execute on function xendit_reconcile_sweep(timestamptz) to service_role;

do $$ begin
  if exists (select 1 from cron.job where jobname = 'studiior-xendit-reconcile') then
    perform cron.unschedule('studiior-xendit-reconcile');
  end if;
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('studiior-xendit-reconcile', '25 3 * * *',
      $c$select xendit_reconcile_sweep()$c$);
  end if;
end $$;

-- =============================================================================
-- 12. member_bootstrap — gains xendit_enabled (a connected 'xendit' row exists).
--     has_payment_provider stays Stripe-specific (it gates a saved-cards screen
--     whose language is untrue of Xendit's hosted checkout). Adding a return
--     column needs drop+recreate; the ACL is re-asserted (authenticated only —
--     NOT anon).
-- =============================================================================
drop function if exists member_bootstrap(text);
create function member_bootstrap(p_slug text)
returns table(member_id uuid, studio_id uuid, first_name text, last_name text,
  preferred_name text, avatar_path text, status member_status, current_streak integer,
  lifetime_visits integer, studio_name text, studio_timezone text, logo_url text,
  theme_preset theme_preset, accent_color text, checkin_opens_minutes_before integer,
  checkin_closes_minutes_after integer, cancellation_cutoff_minutes integer,
  booking_cutoff_minutes integer, waitlist_enabled boolean, billing_status platform_status,
  billing_locked boolean, open_offers integer,
  guest_passes_enabled boolean, has_payment_provider boolean,
  booking_window_days integer, how_to_buy text, studio_contact_email text,
  xendit_enabled boolean)
language sql stable security definer set search_path = public as $function$
  select
    m.id, m.studio_id, m.first_name, m.last_name, m.preferred_name, m.avatar_url,
    m.status, coalesce(m.current_streak, 0), coalesce(m.lifetime_visits, 0),
    s.name, s.timezone, s.logo_url, s.theme_preset, s.accent_color,
    coalesce(st.checkin_opens_minutes_before, 60),
    coalesce(st.checkin_closes_minutes_after, 30),
    coalesce(st.cancellation_cutoff_minutes, 720),
    coalesce(st.booking_cutoff_minutes, 0),
    coalesce(st.waitlist_enabled, true),
    ps.status,
    coalesce(ps.status = 'locked', false),
    (select count(*)::int from waitlist_offers wo
       join bookings b on b.id = wo.booking_id
      where b.member_id = m.id
        and wo.responded_at is null
        and wo.expires_at > now()),
    coalesce(st.guest_passes_enabled, false),
    (s.stripe_account_id is not null),
    member_booking_window_days(m.id),
    st.how_to_buy,
    s.contact_email,
    exists (select 1 from studio_payment_providers spp
             where spp.studio_id = m.studio_id and spp.provider = 'xendit')
  from members m
  join studios s on s.id = m.studio_id
  left join studio_settings st on st.studio_id = m.studio_id
  left join platform_subscriptions ps on ps.studio_id = m.studio_id
  where m.user_id = auth.uid()
    and s.slug = p_slug
  limit 1
$function$;
revoke execute on function member_bootstrap(text) from public, anon;
grant  execute on function member_bootstrap(text) to authenticated, service_role;

-- =============================================================================
-- 13. The anon surface must now be EXACTLY TWELVE — the eleven plus xendit_webhook.
-- =============================================================================
do $$
declare v_n int;
begin
  select count(*) into v_n from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
   where nsp.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if v_n <> 12 then raise exception 'anon surface is % functions, expected 12', v_n; end if;

  if not has_function_privilege('anon', 'xendit_webhook(jsonb, text)'::regprocedure, 'execute') then
    raise exception 'xendit_webhook is not the twelfth anon surface';
  end if;
end $$;
