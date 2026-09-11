-- =============================================================================
-- 102 — Decision 24, part one: a plan may hold only so many people.
--
-- Reform Collective's Unlimited Monthly is 12,000 PHP and the studio cannot
-- sell it to everybody: a room holds twelve reformers, and an unlimited plan
-- sold thirty times is a promise the timetable cannot keep. A seat cap is the
-- plan saying how many people it is for.
--
-- THIS IS THE SMALLEST INDEPENDENT PIECE OF DECISION 24 and it ships first.
-- It shares nothing with peak allowance or the suspension ladder: no ledger,
-- no infractions, no release seam. A studio can turn this on and never see
-- the rest, which is the whole requirement — the three switches are
-- independent and turning one on must not reveal the others.
--
-- OFF BY DEFAULT AND INVISIBLE WHEN OFF. `seat_caps_enabled` defaults false,
-- every plan's cap is null, and `plan_seats()` returns NO ROWS at all for a
-- studio with the switch off — not zeroes, not nulls, nothing for a screen to
-- draw. Existing studios are unaffected in the strong sense: the enforcement
-- branch in activate_purchase() cannot be reached by any of them.
--
-- WHAT IS DELIBERATELY NOT HERE: `on_limit_reached = 'waitlist'`. A waiting
-- list for a PLACE ON A PLAN is a table, an offer with an expiry, a
-- notification template, a staff screen and a promotion path — the class
-- waitlist over again against a different scarce thing. It is more than this
-- pass, so the value is absent from the CHECK rather than accepted and
-- ignored. A setting that stores a choice nothing implements is the
-- decorative control this build refuses to draw. Adding it later is a CHECK
-- change plus the flow, and nothing here has to move.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- The studio switch, in the shape of `flex_enabled` and `guarantees_enabled`.
--
-- Per-plan nullability would have been enough to make the FEATURE off, and not
-- enough to make it INVISIBLE: without this column the plan form grows a
-- "limit places" field on every studio in the world, which is a trace. With it,
-- a studio that has not asked for seat caps is never shown one.
--
-- Enforcement reads this switch as well as the plan's own cap, so turning it
-- off suspends the caps rather than deleting the numbers. Stated plainly
-- because it has a consequence: a studio that switches off, sells thirty, and
-- switches back on is over its cap and will be told so in those words.
-- -----------------------------------------------------------------------------
alter table studio_settings
  add column if not exists seat_caps_enabled boolean not null default false;

comment on column studio_settings.seat_caps_enabled is
  'Decision 24: whether plans in this studio may cap how many members they hold. '
  'Off by default. While off, plan caps are stored but not enforced and no screen shows one.';

-- -----------------------------------------------------------------------------
-- The plan's own three columns.
-- -----------------------------------------------------------------------------
alter table membership_plans
  add column if not exists max_active_members   int,
  add column if not exists show_remaining_below int,
  add column if not exists on_limit_reached     text not null default 'hide';

comment on column membership_plans.max_active_members is
  'Decision 24: how many members may hold this plan at once. Null means no limit, '
  'which is every plan until a studio says otherwise. Counts ACTIVE holders, never lifetime sales.';
comment on column membership_plans.show_remaining_below is
  'Show "N places left" to a member once remaining drops to this or below. Null means never say.';
comment on column membership_plans.on_limit_reached is
  'What a full plan does: hide it, or leave it sellable at the desk only.';

alter table membership_plans
  drop constraint if exists plan_seat_cap_positive,
  drop constraint if exists plan_show_remaining_needs_cap,
  drop constraint if exists plan_on_limit_reached_known;

alter table membership_plans
  add constraint plan_seat_cap_positive
    check (max_active_members is null or max_active_members > 0),
  -- A "places left" threshold on a plan with no limit is a countdown from
  -- infinity. It can only have been a mistake, so it is refused rather than
  -- stored and quietly ignored.
  add constraint plan_show_remaining_needs_cap
    check (show_remaining_below is null
           or (show_remaining_below > 0 and max_active_members is not null)),
  -- 'waitlist' is not in this list on purpose. See the header.
  add constraint plan_on_limit_reached_known
    check (on_limit_reached in ('hide', 'staff_only'));

-- -----------------------------------------------------------------------------
-- ONE DEFINITION OF A TAKEN SEAT, and everything asks it.
--
-- The four counted statuses are the four ways of holding a place:
--
--   active    — obviously.
--   trialing  — a trial of this plan is a person on this plan.
--   past_due  — a member who owes money has not left. Freeing their place the
--               day a card fails would sell it out from under somebody the
--               studio is still chasing, and §7.3's grace exists precisely
--               because that is not what a failed payment means.
--   frozen    — THE SEAT AND THE RATE ARE WHAT FREEZING IS FOR. A member who
--               pauses for January and comes back to find their place sold and
--               the price raised has not been given a freeze, they have been
--               given a cancellation with extra steps.
--
-- cancelled and expired are not counted, and that is the other half of the
-- same rule: leaving the plan frees the place, and somebody who leaves and
-- comes back buys at whatever the plan costs that day (§7.1 snapshots the
-- price at purchase, so the old rate left with them).
--
-- Unguarded internal, closed to every client role — the shape of
-- rebuild_timeline_rows() behind rebuild_member_timeline(). The guard lives on
-- plan_seats(), which is what a screen calls.
-- -----------------------------------------------------------------------------
create or replace function plan_seats_taken(p_plan_id uuid)
returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int
    from memberships
   where plan_id = p_plan_id
     and status in ('trialing', 'active', 'past_due', 'frozen');
$$;

-- -----------------------------------------------------------------------------
-- What a screen asks. One row per capped plan, or NO ROWS when the studio has
-- the switch off — so "this studio does not use seat caps" and "this plan has
-- no cap" are the same absence and neither renders anything.
--
-- Guarded, because it is SECURITY DEFINER and takes an id that returns tenant
-- data (migration 056). Staff below front desk are not offered it at all:
-- `plans_staff_read` excludes instructors and `is_desk_up()` agrees.
--
-- A member sees only what `plans_member_read` would have shown them — public
-- plans — because this function steps over that policy and has to re-state it.
-- Nothing in the member app lists plans today, so that branch has no caller
-- yet; it is written correctly now rather than discovered later.
--
-- `taken` is the truth and `remaining` is floored at zero, so a plan holding
-- twelve against a cap of ten reads "12 of 10" rather than "0 left". A studio
-- can go over — an import brings existing members in without asking, and
-- switching the feature off and on again can strand a plan above its cap —
-- and a screen that could not say so would be lying about their own studio.
-- -----------------------------------------------------------------------------
create or replace function plan_seats(p_studio_id uuid)
returns table (
  plan_id          uuid,
  cap              int,
  taken            int,
  remaining        int,
  is_full          boolean,
  is_over          boolean,
  show_remaining   boolean,
  on_limit_reached text)
language plpgsql stable security definer set search_path = public as $$
declare
  v_staff boolean;
  v_member boolean;
begin
  v_staff  := is_desk_up(p_studio_id);
  v_member := p_studio_id in (select auth_member_studios());
  if not (coalesce(v_staff, false) or coalesce(v_member, false)) then
    raise exception 'that studio is not yours' using errcode = 'PT403';
  end if;

  -- The switch, before anything else. No rows is the answer, not zero rows
  -- of zeroes.
  if not coalesce((select ss.seat_caps_enabled from studio_settings ss
                    where ss.studio_id = p_studio_id), false) then
    return;
  end if;

  return query
  select pl.id,
         pl.max_active_members,
         t.taken,
         greatest(pl.max_active_members - t.taken, 0),
         t.taken >= pl.max_active_members,
         t.taken >  pl.max_active_members,
         pl.show_remaining_below is not null
           and t.taken < pl.max_active_members
           and (pl.max_active_members - t.taken) <= pl.show_remaining_below,
         pl.on_limit_reached
    from membership_plans pl
    cross join lateral (select plan_seats_taken(pl.id) as taken) t
   where pl.studio_id = p_studio_id
     and pl.max_active_members is not null
     and pl.status = 'active'
     and (coalesce(v_staff, false) or pl.visibility = 'public');
end $$;

-- -----------------------------------------------------------------------------
-- THE SALE, AND THE RACE.
--
-- activate_purchase() is the only thing in the product that creates a
-- membership — Decision 16's whole argument is that a cash sale and a Stripe
-- sale are one path — so the cap is checked here and nowhere else.
--
-- THE PLAN ROW IS LOCKED FIRST. Counting and then inserting is check-then-act,
-- which overbooks under load exactly as it would have in book_class(); the
-- lock makes the count and the insert one serialised step per plan. It is
-- taken whether or not the plan is capped, because deciding whether to lock by
-- reading the cap first is itself the read-then-write this is avoiding, and
-- one extra row lock on a sale costs nothing. (It is not a wall against a
-- hand-written INSERT into `memberships`, which takes no lock and answers to
-- nothing — the same standing caveat as `booked_count`.)
--
-- p_enforce_seat_cap EXISTS FOR ONE CALLER AND THE REASON IS MONEY.
-- The desk selling at the counter can be refused: nobody has paid, and "this
-- plan is full" is a useful sentence to a person standing there. A completed
-- Stripe checkout cannot: the charge has already been captured, and raising
-- inside the webhook would return a non-2xx, make Stripe retry for days, and
-- leave a member who has paid holding no membership at all. Money that has
-- already moved is honoured, the studio goes one over, and every screen says
-- so. A parameter rather than a transaction-local flag because the caller is
-- calling the function directly — the flags in this codebase exist where a
-- trigger cannot see which path is running, which is not the case here.
--
-- DROPPED AND RECREATED, not replaced: a new parameter with a default creates
-- an OVERLOAD rather than replacing a signature, and every seven-argument call
-- then fails as ambiguous (migration 028's trap). A drop discards the ACL, so
-- the grants are re-asserted at the bottom of this migration and then checked
-- (migration 094's).
-- -----------------------------------------------------------------------------
drop function if exists activate_purchase(uuid, uuid, uuid, int, char, text, text);

create function activate_purchase(
  p_studio_id uuid, p_member_id uuid, p_plan_id uuid, p_price_cents int,
  p_currency char(3), p_stripe_customer text default null,
  p_stripe_subscription text default null,
  p_enforce_seat_cap boolean default true)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  plan membership_plans%rowtype; v_ms uuid; v_bal int;
  v_today date; v_start timestamptz; v_end timestamptz;
  v_taken int;
begin
  -- Locked. See above.
  select * into plan from membership_plans
   where id = p_plan_id and studio_id = p_studio_id
   for update;
  if not found then
    raise exception 'no such plan for this studio' using errcode = 'PT404';
  end if;
  if not exists (select 1 from members where id = p_member_id and studio_id = p_studio_id) then
    raise exception 'that member does not belong to this studio' using errcode = 'PT403';
  end if;

  -- Decision 24: the seat cap, under the lock, before anything is written.
  if coalesce(p_enforce_seat_cap, true)
     and plan.max_active_members is not null
     and coalesce((select ss.seat_caps_enabled from studio_settings ss
                    where ss.studio_id = p_studio_id), false)
  then
    v_taken := plan_seats_taken(plan.id);
    if v_taken >= plan.max_active_members then
      raise exception '% is full: % of % places are taken.',
                      plan.name, v_taken, plan.max_active_members
        using errcode = 'PT409',
              hint = 'Somebody has to leave this plan, or its limit has to go up, '
                     'before another place can be sold.';
    end if;
  end if;

  v_today := studio_today(p_studio_id);
  v_start := now();
  -- Null for a pack, a drop-in and a trial, which is what makes the columns
  -- mean something: a period present is a thing that renews.
  v_end   := plan_period_end(plan.id, v_start);

  insert into memberships (
    studio_id, member_id, plan_id, status, price_cents, currency, starts_on,
    current_period_start, current_period_end, renews_on, credits_reset_at,
    credits_remaining, expires_on, auto_renew,
    stripe_customer_id, stripe_subscription_id
  ) values (
    p_studio_id, p_member_id, plan.id,
    (case when plan.type = 'trial' then 'trialing' else 'active' end)::membership_status,
    -- §7.1: the price agreed at purchase, snapshotted. Never re-read from the
    -- plan afterwards, so editing a plan cannot reprice anybody already on it.
    coalesce(p_price_cents, plan.price_cents),
    coalesce(nullif(p_currency, ''), plan.currency),
    v_today,
    v_start, v_end,
    -- renews_on is the period end as one of the STUDIO's dates.
    (v_end at time zone (select s.timezone from studios s where s.id = p_studio_id))::date,
    -- Decision 3: no rollover. The allowance resets at the period boundary
    -- rather than accumulating, and only where there is an allowance at all —
    -- Decision 12 makes a null credits_per_period mean unlimited.
    case when plan.type = 'recurring' and plan.credits_per_period is not null
         then v_end end,
    case when plan.type = 'class_pack' then plan.credits else plan.credits_per_period end,
    case when plan.type = 'class_pack' and plan.validity_days is not null
         then v_today + plan.validity_days end,
    plan.type = 'recurring',
    p_stripe_customer, nullif(p_stripe_subscription, '')
  ) returning id into v_ms;

  -- §6: a pack's classes arrive as ledger rows. credits_remaining above is a
  -- cache of this, written in the same transaction and never independently.
  if plan.type = 'class_pack' and coalesce(plan.credits, 0) > 0 then
    select coalesce(sum(delta), 0) into v_bal
      from credit_ledger where studio_id = p_studio_id and member_id = p_member_id;
    insert into credit_ledger (studio_id, member_id, membership_id, delta, reason,
                               balance_after, expires_at, actor_user_id)
    values (p_studio_id, p_member_id, v_ms, plan.credits, 'purchase',
            v_bal + plan.credits,
            case when plan.validity_days is not null
                 then (v_today + plan.validity_days + 1)::timestamptz end,
            auth.uid());
  end if;

  insert into membership_events (studio_id, membership_id, type, to_status, actor_user_id)
  values (p_studio_id, v_ms, 'created',
          (case when plan.type = 'trial' then 'trialing' else 'active' end)::membership_status,
          auth.uid());

  return v_ms;
end $$;

-- -----------------------------------------------------------------------------
-- The Stripe handler, re-issued verbatim from migration 051 — the file that
-- last defined it, never from the database — for the one line that changes.
-- -----------------------------------------------------------------------------
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
  v_ms        uuid;
begin
  if v_member is not null and not exists (
    select 1 from members where id = v_member and studio_id = p_studio_id
  ) then
    raise exception 'that member does not belong to this studio' using errcode = 'PT403';
  end if;

  if v_kind = 'dropin' then
    perform confirm_dropin_payment(p_studio_id, v_booking);

    update payments
       set status = 'succeeded', paid_at = now(), provider = 'stripe',
           stripe_payment_intent_id = p_obj ->> 'payment_intent',
           amount_cents = v_amount, currency = v_currency, updated_at = now()
     where booking_id = v_booking and studio_id = p_studio_id and status = 'pending';

    if not found then
      insert into payments (studio_id, member_id, booking_id, amount_cents, currency,
                            status, provider, description, stripe_payment_intent_id, paid_at)
      values (p_studio_id, v_member, v_booking, v_amount, v_currency,
              'succeeded', 'stripe', 'Drop-in class', p_obj ->> 'payment_intent', now());
    end if;
    return 'dropin_paid';
  end if;

  -- The shared grant. Everything about what a plan gives a member — the
  -- snapshot, the pack credits, the expiry, the audit row — lives there and is
  -- identical to what the front desk gets when they record cash.
  --
  -- Decision 24: the seat cap is NOT enforced here, and this false is the only
  -- line in this function that has changed. Stripe has already captured the
  -- money by the time this event arrives, so refusing would return a non-2xx,
  -- be retried for days, and leave somebody who has paid holding no
  -- membership. The studio goes one over its cap and every screen says so.
  v_ms := activate_purchase(p_studio_id, v_member, v_plan,
                            coalesce(v_snapshot, v_amount), v_currency,
                            p_obj ->> 'customer', nullif(p_obj ->> 'subscription', ''),
                            false);

  insert into payments (studio_id, member_id, membership_id, amount_cents, currency,
                        status, provider, description, stripe_payment_intent_id, paid_at)
  select p_studio_id, v_member, v_ms, v_amount, v_currency, 'succeeded', 'stripe',
         mp.name, p_obj ->> 'payment_intent', now()
    from membership_plans mp where mp.id = v_plan;

  return 'membership_created';
end $$;

-- -----------------------------------------------------------------------------
-- Grants. activate_purchase() was dropped, so its ACL went with it and is
-- re-stated here rather than assumed.
-- -----------------------------------------------------------------------------
revoke execute on function activate_purchase(uuid, uuid, uuid, int, char, text, text, boolean)
  from public, anon, authenticated;
grant  execute on function activate_purchase(uuid, uuid, uuid, int, char, text, text, boolean)
  to service_role;

revoke execute on function plan_seats_taken(uuid) from public, anon, authenticated;
grant  execute on function plan_seats_taken(uuid) to service_role;

revoke execute on function plan_seats(uuid) from public, anon;
grant  execute on function plan_seats(uuid) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- And asserted, in the migration, because hosted's default privileges name
-- `anon` and `authenticated` explicitly and a local reset cannot tell you.
-- -----------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as sig,
           has_function_privilege('anon', p.oid, 'execute') as anon,
           has_function_privilege('authenticated', p.oid, 'execute') as authed
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('activate_purchase', 'plan_seats_taken',
                         'plan_seats', 'stripe_handle_checkout_completed')
  loop
    if r.anon then
      raise exception 'migration 102: % is reachable by anon', r.sig;
    end if;
    if r.authed and r.sig not like 'plan_seats(%' then
      raise exception 'migration 102: % is reachable by authenticated', r.sig;
    end if;
  end loop;
end $$;
